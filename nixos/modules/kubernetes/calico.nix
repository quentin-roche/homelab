{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.kubernetes;
  packages = import ./packages.nix { inherit pkgs; };
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
        lib.replaceStrings
          [ "@INTERFACE@" "@POD_CIDR@" "@NODE_IP@" ]
          [ cfg.interface cfg.podCIDR cfg.nodeIP ]
          (builtins.readFile ./calico/node.yaml.in)
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
  config = lib.mkIf cfg.enable {
    boot.kernelModules = [
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

    services.k3s.manifests = {
      "00-calico".source = calico;
      "20-host-security".source = hostSecurity;
    };
  };
}
