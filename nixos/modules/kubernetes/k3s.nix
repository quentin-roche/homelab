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
    ];
    systemd.services.k3s.unitConfig.ConditionPathExists = "!${cfg.recoveryHoldFile}";
    services.k3s = {
      enable = true;
      role = "server";
      nodeName = cfg.nodeName;
      nodeIP = cfg.nodeIP;
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
        "10-workload-security".source = ./workload-security.yaml;
      };
    };
  };
}
