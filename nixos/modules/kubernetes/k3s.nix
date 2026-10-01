{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.kubernetes;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/var/lib/" cfg.recoveryHoldFile;
        message = "The recovery hold marker must be outside the Nix store, under /var/lib/.";
      }
    ];
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
    systemd.services.k3s.path = with pkgs; [
      iproute2
      iptables
      util-linux
      ethtool
      jq
    ];
    # Wait for the selected interface, including a host-owned dummy interface.
    systemd.services.k3s.preStart = ''
      for task_attempt in $(seq 1 30); do
        if ip -j -4 address show dev ${lib.escapeShellArg cfg.interface} 2>/dev/null |
          jq -e --arg ip ${lib.escapeShellArg cfg.nodeIP} 'any(.[].addr_info[]; .local == $ip)' >/dev/null; then
          exit 0
        fi
        sleep 1
      done
      echo "Kubernetes node address is not ready" >&2
      exit 1
    '';
    systemd.services.k3s.unitConfig.ConditionPathExists = "!${cfg.recoveryHoldFile}";
    services.k3s = {
      enable = true;
      role = "server";
      nodeName = cfg.nodeName;
      nodeIP = cfg.nodeIP;
      extraKubeletConfig.address = cfg.nodeIP;
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
          "bind-address" = cfg.nodeIP;
          "tls-san" = [ cfg.nodeIP ];
          "secrets-encryption" = true;
          "write-kubeconfig-mode" = "0600";
        }
      );
      manifests = {
        "10-workload-security".source = ./workload-security.yaml;
      };
    };
  };
}
