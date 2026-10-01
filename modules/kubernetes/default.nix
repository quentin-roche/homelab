{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.kubernetes;
  packages = import ./packages.nix { inherit pkgs; };
  inherit (packages) kata;
  kataConfig = pkgs.runCommand "kata.toml" { } ''
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
  calicoOverlay = pkgs.linkFarm "calico-overlay" [
    {
      name = "kustomization.yaml";
      path = ./calico/kustomization.yaml;
    }
    {
      name = "config.yaml";
      path = ./calico/config.yaml;
    }
    {
      name = "node.yaml";
      path = pkgs.writeText "calico-node.yaml" (
        lib.replaceStrings [ "@INTERFACE@" "@POD_CIDR@" ] [ cfg.interface cfg.podCIDR ] (
          builtins.readFile ./calico/node.yaml.in
        )
      );
    }
  ];
  calico = packages.render {
    name = "calico.yaml";
    upstream = packages.calico;
    overlay = calicoOverlay;
  };
  hostSecurity = pkgs.writeText "host-security.yaml" (
    lib.replaceStrings
      [ "@NODE_NAME@" "@NODE_IP@" "@LAN_CIDR@" "@POD_CIDR@" "@SERVICE_CIDR@" "@DNS_CIDRS@" ]
      [
        cfg.nodeName
        cfg.nodeIP
        cfg.lanCIDR
        cfg.podCIDR
        cfg.serviceCIDR
        (builtins.toJSON cfg.dnsServerCIDRs)
      ]
      (builtins.readFile ./host-security.yaml.in)
  );
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
  networkGuard = pkgs.writeText "homelab-network-guard.nft" ''
    add table inet homelab_guard
    add chain inet homelab_guard input { type filter hook input priority 10; policy accept; }
    add chain inet homelab_guard forward { type filter hook forward priority 10; policy accept; }
    flush chain inet homelab_guard input
    flush chain inet homelab_guard forward
    add rule inet homelab_guard input ct state established,related return
    add rule inet homelab_guard forward ct state established,related return
    add rule inet homelab_guard input iifname "cali*" meta mark & 0x10000 != 0x10000 counter drop
    add rule inet homelab_guard forward iifname "cali*" meta mark & 0x10000 != 0x10000 counter drop
    add rule inet homelab_guard forward oifname "cali*" meta mark & 0x10000 != 0x10000 counter drop
  '';
in
{
  imports = [ ./flux.nix ];
  options.homelab.kubernetes = {
    enable = lib.mkEnableOption "K3s with Kata VM isolation and Calico policy";
    nodeName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Kubernetes node and Calico host endpoint name.";
    };
    nodeIP = lib.mkOption {
      type = lib.types.str;
      description = "Static IPv4 address of this node.";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      description = "Host interface used for Calico address detection.";
    };
    lanCIDR = lib.mkOption {
      type = lib.types.str;
      description = "IPv4 LAN permitted to use SSH and DHCP.";
    };
    dnsServerCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Host DNS resolvers as IPv4/IPv6 CIDRs.";
    };
    recoveryHoldFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/homelab/restore-in-progress";
      description = "External marker that prevents K3s and Flux credential startup until restored data is ready.";
    };
    podCIDR = lib.mkOption {
      type = lib.types.str;
      default = "10.42.0.0/16";
      description = "IPv4 pod network.";
    };
    serviceCIDR = lib.mkOption {
      type = lib.types.str;
      default = "10.43.0.0/16";
      description = "IPv4 service network.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "The pinned Kata bundle supports x86_64-linux only.";
      }
      {
        assertion = lib.hasPrefix "/var/lib/" cfg.recoveryHoldFile;
        message = "The recovery hold marker must be outside the Nix store, under /var/lib/.";
      }
    ];
    boot.kernelModules = [
      "vhost_vsock"
      "vhost_net"
      "tun"
      "overlay"
      "br_netfilter"
    ];
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
    };
    networking.firewall.checkReversePath = false;
    # Calico owns forwarding policy. Keep the Kubernetes API off the LAN.
    services.openssh.openFirewall = false;
    networking.firewall.extraCommands = ''
      iptables -A nixos-fw -p tcp -s ${lib.escapeShellArg cfg.lanCIDR} --dport 22 -j nixos-fw-accept
      # Only packets already approved by Calico can reach the API/kubelet.
      iptables -A nixos-fw -i cali+ -p tcp -m multiport --dports 6443,10250 -m mark --mark 0x10000/0x10000 -j nixos-fw-accept
    '';
    environment.systemPackages = with pkgs; [
      kubectl
      kubernetes-helm
      iproute2
      iptables
      nftables
      jq
      util-linux
      curl
    ];
    systemd.tmpfiles.rules = [
      "d /var/lib/rancher/k3s/agent/etc/containerd 0755 root root -"
      "L+ /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl - - - - ${containerdTemplate}"
    ];
    systemd.services.k3s.path = with pkgs; [
      iproute2
      iptables
      util-linux
      ethtool
    ];
    systemd.services.k3s.restartTriggers = [
      containerdTemplate
      kataConfig
    ];
    # Run after iptables' filter hooks. Even if Felix has not installed its rules
    # yet, pod traffic cannot pass without Calico's host-side acceptance mark.
    # nft applies the entire file as one transaction, including during reloads.
    systemd.services.homelab-network-guard = {
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
    systemd.services.k3s.requires = [ "homelab-network-guard.service" ];
    systemd.services.k3s.after = [ "homelab-network-guard.service" ];
    systemd.services.k3s.unitConfig.ConditionPathExists = "!${cfg.recoveryHoldFile}";
    services.k3s = {
      enable = true;
      role = "server";
      nodeName = cfg.nodeName;
      nodeIP = cfg.nodeIP;
      nodeLabel = [ "homelab/kata=true" ];
      configPath = pkgs.writeText "k3s-config.yaml" (
        builtins.toJSON {
          "flannel-backend" = "none";
          "disable-network-policy" = true;
          "disable" = [
            "traefik"
            "servicelb"
          ];
          "cluster-cidr" = cfg.podCIDR;
          "service-cidr" = cfg.serviceCIDR;
          "advertise-address" = cfg.nodeIP;
          "secrets-encryption" = true;
          "write-kubeconfig-mode" = "0600";
        }
      );
      manifests = {
        "00-calico".source = calico;
        "10-workload-security".source = ./workload-security.yaml;
        "20-host-security".source = hostSecurity;
      };
    };
  };
}
