{ config, pkgs, ... }:
let
  kata = import ./kata.nix { inherit pkgs; };
  kataConfig = pkgs.runCommand "kata-chopin.toml" { } ''
    cp ${kata}/share/defaults/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml "$out"
    chmod u+w "$out"
    sed -i \
      -e 's/^enable_annotations = .*/enable_annotations = []/' \
      -e 's/^default_memory = .*/default_memory = 1024/' \
      -e 's/^overhead_memory = .*/overhead_memory = 256/' \
      -e 's|^firmware = .*|firmware = "${kata}/share/kata-qemu/qemu/bios-256k.bin"|' \
      -e 's/^disable_guest_seccomp = .*/disable_guest_seccomp = false/' \
      "$out"
  '';
  upstreamCalico = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/calico.yaml";
    sha256 = "a8c828a06a87c629a282ebbc424895b77f3a030251993e41ea400a743675bb02";
  };
  calico = pkgs.runCommand "calico-chopin.yaml" {
    nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pyyaml ])) ];
  } ''
    python ${./calico.py} ${upstreamCalico} > "$out"
  '';
  containerdTemplate = pkgs.writeText "config-v3.toml.tmpl" ''
    {{ template "base" . }}
    {{ if not (or .NodeConfig.AgentConfig.CNIBinDir .NodeConfig.AgentConfig.CNIConfDir) }}
    [plugins.'io.containerd.cri.v1.runtime'.cni]
      bin_dirs = ["/var/lib/rancher/k3s/data/cni"]
      conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d"
    {{ end }}
    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata-qemu]
      runtime_type = "io.containerd.kata.v2"
      runtime_path = "${kata}/runtime-rs/bin/containerd-shim-kata-v2"
      privileged_without_host_devices = true
    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata-qemu.options]
      ConfigPath = "${kataConfig}"
  '';
  networkGuard = pkgs.writeText "chopin-network-guard.nft" ''
    add table inet chopin_guard
    add chain inet chopin_guard input { type filter hook input priority 10; policy accept; }
    add chain inet chopin_guard forward { type filter hook forward priority 10; policy accept; }
    flush chain inet chopin_guard input
    flush chain inet chopin_guard forward
    add rule inet chopin_guard input ct state established,related return
    add rule inet chopin_guard forward ct state established,related return
    add rule inet chopin_guard input iifname "cali*" meta mark & 0x10000 != 0x10000 counter drop
    add rule inet chopin_guard forward iifname "cali*" meta mark & 0x10000 != 0x10000 counter drop
    add rule inet chopin_guard forward oifname "cali*" meta mark & 0x10000 != 0x10000 counter drop
  '';
in {
  boot.kernelModules = [ "kvm-amd" "vhost_vsock" "vhost_net" "tun" "overlay" "br_netfilter" ];
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
  };
  networking.firewall.checkReversePath = false;
  # Calico owns forwarding policy. Keep the Kubernetes API off the LAN.
  services.openssh.openFirewall = false;
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp -s 192.168.1.0/24 --dport 22 -j nixos-fw-accept
    # Only packets already approved by Calico can reach the API/kubelet.
    iptables -A nixos-fw -i cali+ -p tcp -m multiport --dports 6443,10250 -m mark --mark 0x10000/0x10000 -j nixos-fw-accept
  '';
  environment.systemPackages = with pkgs; [ git kubectl kubernetes-helm iproute2 iptables nftables jq util-linux curl ];
  systemd.tmpfiles.rules = [
    "d /var/lib/rancher/k3s/agent/etc/containerd 0755 root root -"
    "L+ /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl - - - - ${containerdTemplate}"
  ];
  systemd.services.k3s.path = with pkgs; [ iproute2 iptables util-linux ethtool ];
  systemd.services.k3s.restartTriggers = [ containerdTemplate kataConfig ];
  # Run after iptables' filter hooks. Even if Felix has not installed its rules
  # yet, pod traffic cannot pass without Calico's host-side acceptance mark.
  # nft applies the entire file as one transaction, including during reloads.
  systemd.services.chopin-network-guard = {
    description = "Fail closed until Calico approves workload packets";
    wantedBy = [ "multi-user.target" ];
    before = [ "k3s.service" ];
    after = [ "firewall.service" ];
    reloadIfChanged = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.nftables}/bin/nft -f ${networkGuard}";
      ExecReload = "${pkgs.nftables}/bin/nft -f ${networkGuard}";
    };
  };
  systemd.services.k3s.requires = [ "chopin-network-guard.service" ];
  systemd.services.k3s.after = [ "chopin-network-guard.service" ];
  services.k3s = {
    enable = true;
    role = "server";
    nodeName = "chopin";
    nodeIP = "192.168.1.82";
    nodeLabel = [ "homelab/kata=true" ];
    configPath = pkgs.writeText "k3s-config.yaml" (builtins.toJSON {
      "flannel-backend" = "none";
      "disable-network-policy" = true;
      "disable" = [ "traefik" "servicelb" ];
      "cluster-cidr" = "10.42.0.0/16";
      "service-cidr" = "10.43.0.0/16";
      "advertise-address" = "192.168.1.82";
      "secrets-encryption" = true;
      "write-kubeconfig-mode" = "0600";
    });
    manifests = {
      "00-calico".source = calico;
      "10-workload-security".source = ./workload-security.yaml;
      "20-host-security".source = ./host-security.yaml;
    };
  };
}
