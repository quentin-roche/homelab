{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.kubernetes;
  dependencies = import ./packages.nix { inherit pkgs; };
  python = pkgs.python3.withPackages (p: [ p.pyyaml ]);
  security =
    pkgs.runCommand "platform-security.yaml"
      {
        nativeBuildInputs = [
          python
          pkgs.kubernetes-helm
        ];
      }
      ''
        python ${../../../scripts/render_platform_security.py} \
          --release ${../../../kubernetes/infrastructure/traefik/release.yaml} \
          --chart ${dependencies.platformCharts.traefik} > "$out"
        printf '\n---\n' >> "$out"
        python ${../../../scripts/render_platform_security.py} \
          --release ${../../../kubernetes/infrastructure/cert-manager/release.yaml} \
          --chart ${dependencies.platformCharts.cert-manager} >> "$out"
      '';
  serviceOctets = lib.splitString "." (builtins.head (lib.splitString "/" cfg.serviceCIDR));
  apiIP = lib.concatStringsSep "." (
    lib.take 3 serviceOctets ++ [ (toString (lib.toInt (lib.last serviceOctets) + 1)) ]
  );
  network = pkgs.writeText "platform-network.yaml" (
    lib.replaceStrings
      [ "@NODE_NAME@" "@NODE_IP@" "@API_IP@" "@LAN_CIDR@" "@POD_CIDR@" "@SERVICE_CIDR@" ]
      [ cfg.nodeName cfg.nodeIP apiIP cfg.lanCIDR cfg.podCIDR cfg.serviceCIDR ]
      (builtins.readFile ./platform/network-policy.yaml.in)
  );
in
{
  options.homelab.kubernetes.platform.enable =
    lib.mkEnableOption "administrator-owned prerequisites for Flux-managed Traefik and cert-manager";
  config = lib.mkIf (cfg.enable && cfg.platform.enable) {
    assertions = [
      {
        assertion = cfg.flux.enable;
        message = "The platform controllers require Flux.";
      }
    ];
    services.k3s.manifests = {
      "34-platform-security".source = security;
      "35-platform-network".source = network;
      "36-platform-reconciler".source = ./platform/reconciler.yaml;
    };
    networking.firewall.allowedTCPPorts = [
      30080
      30443
    ];
  };
}
