{ config, pkgs, ... }:
let
  exampleWeb = pkgs.runCommand "example-web.yaml" {} ''
    sed '/^    metadata:$/a\      annotations:\n        homelab.example/sidecar-revision: "${config.homelab.tailnet.sidecarRevision}"' ${./examples/application.yaml} > "$out"
  '';
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
  kataCni = pkgs.writeTextDir "10-kata.conflist" (builtins.toJSON {
    cniVersion = "1.0.0";
    name = "kata-transport";
    plugins = [{
      type = "bridge"; bridge = "kata0"; isGateway = true;
      ipMasq = false; mtu = 1500;
      ipam = { type = "host-local"; ranges = [[{ subnet = "10.44.0.0/24"; }]];
        routes = [{ dst = "0.0.0.0/0"; }]; };
    }];
  });
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
      privileged_without_host_devices_all_devices_allowed = true
      cni_conf_dir = "${kataCni}"
    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata-qemu.options]
      ConfigPath = "${kataConfig}"
  '';
  networkGuard = pkgs.writeText "chopin-network-guard.nft" ''
    add table inet chopin_kata_guard
    add chain inet chopin_kata_guard input { type filter hook input priority -10; policy accept; }
    add chain inet chopin_kata_guard forward { type filter hook forward priority -10; policy accept; }
    flush chain inet chopin_kata_guard input
    flush chain inet chopin_kata_guard forward
    # Provenance is the bridge, not a guest-controlled source address.
    add rule inet chopin_kata_guard input iifname "kata0" ip daddr 192.168.1.82 tcp dport 8080 accept
    add rule inet chopin_kata_guard input iifname "kata0" ip daddr { 192.168.1.82, 10.44.0.1 } udp dport 41641 accept
    add rule inet chopin_kata_guard input iifname "kata0" counter drop
    add rule inet chopin_kata_guard forward iifname "kata0" oifname "kata0" ip daddr 10.44.0.0/24 udp dport 41641 accept
    # DNS is infrastructure, not an application access allowlist.
    add rule inet chopin_kata_guard forward iifname "kata0" ip daddr 10.42.0.0/24 udp dport 53 accept
    add rule inet chopin_kata_guard forward iifname "kata0" ip daddr 10.42.0.0/24 tcp dport 53 accept
    add rule inet chopin_kata_guard forward iifname "kata0" counter drop
    add rule inet chopin_kata_guard forward oifname "kata0" ct state established,related accept
    add rule inet chopin_kata_guard forward oifname "kata0" ip saddr 10.44.0.0/24 udp dport 41641 accept
    add rule inet chopin_kata_guard forward oifname "kata0" ip saddr 192.168.1.82 udp dport 41641 accept
    add rule inet chopin_kata_guard forward oifname "kata0" counter drop
    # An explicit bridge hook also covers locally switched packets.
    add table bridge chopin_kata_guard
    add chain bridge chopin_kata_guard forward { type filter hook forward priority -200; policy accept; }
    flush chain bridge chopin_kata_guard forward
    add rule bridge chopin_kata_guard forward meta ibrname "kata0" ether type arp accept
    add rule bridge chopin_kata_guard forward meta ibrname "kata0" ether type ip ip daddr 10.44.0.0/24 udp dport 41641 accept
    add rule bridge chopin_kata_guard forward meta ibrname "kata0" counter drop
  '';

in {
  imports = [ ./tailscale ];
  boot.kernelModules = [ "kvm-amd" "vhost_vsock" "vhost_net" "tun" "overlay" "br_netfilter" ];
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
  };
  networking.firewall.checkReversePath = false;
  services.openssh.openFirewall = false;
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp -s 192.168.1.0/24 --dport 22 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp -s 192.168.1.0/24 --dport 8080 -j nixos-fw-accept
    iptables -A nixos-fw -i kata0 -p tcp --dport 8080 -j nixos-fw-accept
    iptables -A nixos-fw -i kata0 -p udp --dport 41641 -j nixos-fw-accept
    iptables -A nixos-fw -p udp -s 192.168.1.0/24 --dport 41641 -j nixos-fw-accept
    iptables -A nixos-fw -i cni0 -p tcp -m multiport --dports 6443,10250 -j nixos-fw-accept
    iptables -A nixos-fw -i tailscale0 -j nixos-fw-accept
  '';
  environment.systemPackages = with pkgs; [ git kubectl kubernetes-helm iproute2 iptables nftables jq util-linux curl ];
  systemd.tmpfiles.rules = [
    "d /var/lib/rancher/k3s/agent/etc/containerd 0755 root root -"
    "L+ /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl - - - - ${containerdTemplate}"
  ];
  systemd.services.k3s.path = with pkgs; [ iproute2 iptables util-linux ethtool ];
  systemd.services.k3s.restartTriggers = [ containerdTemplate kataConfig ];
  # nft applies the host transport boundary atomically, before K3s starts.
  systemd.services.chopin-network-guard = {
    description = "Restrict Kata guests to Headscale, encrypted peer transport and DNS";
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
  systemd.services.chopin-retire-calico = {
    description = "Migrate legacy Calico infrastructure to Flannel";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s.service" ];
    requires = [ "k3s.service" ];
    before = [ "chopin-tailnet-enrollment.service" ];
    path = with pkgs; [ k3s iptables iproute2 nftables coreutils gnused bash ];
    restartTriggers = [ ./retire-calico.sh ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
    script = "bash ${./retire-calico.sh}";
  };
  services.k3s = {
    enable = true;
    role = "server";
    nodeName = "chopin";
    nodeIP = "192.168.1.82";
    nodeLabel = [ "homelab/kata=true" ];
    configPath = pkgs.writeText "k3s-config.yaml" (builtins.toJSON {
      "flannel-backend" = "host-gw";
      "kube-apiserver-arg" = [
        "feature-gates=MutatingAdmissionPolicy=true"
        "runtime-config=admissionregistration.k8s.io/v1beta1=true"
      ];
      "disable-network-policy" = true;
      "disable" = [ "traefik" "servicelb" ];
      "cluster-cidr" = "10.42.0.0/16";
      "service-cidr" = "10.43.0.0/16";
      "advertise-address" = "192.168.1.82";
      "secrets-encryption" = true;
      "write-kubeconfig-mode" = "0600";
    });
    manifests = {
      "30-example-web".source = exampleWeb;
      "10-workload-security".source = ./workload-security.yaml;
    };
  };
}
