{
  config,
  lib,
  pkgs,
  ...
}:
let
  cluster = config.homelab.kubernetes;
  cfg = cluster.flux;
  packages = import ./packages.nix { inherit pkgs; };
  distribution = packages.flux;
  runtime = packages.render {
    name = "flux-runtime.yaml";
    upstream = distribution.install;
    overlay = ./flux;
  };
  serviceOctets = lib.splitString "." (builtins.head (lib.splitString "/" cluster.serviceCIDR));
  apiIP = lib.concatStringsSep "." (
    lib.take 3 serviceOctets ++ [ (toString (lib.toInt (lib.last serviceOctets) + 1)) ]
  );
  networkPolicy = pkgs.writeText "flux-network-policy.yaml" (
    lib.replaceStrings
      [ "@NODE_IP@" "@API_IP@" "@SERVICE_CIDR@" "@POD_CIDR@" "@LAN_CIDR@" ]
      [ cluster.nodeIP apiIP cluster.serviceCIDR cluster.podCIDR cluster.lanCIDR ]
      (builtins.readFile ./flux/network-policy.yaml.in)
  );
  sync = import ./flux/sync.nix { inherit pkgs lib cfg; };
in
{
  options.homelab.kubernetes.flux = {
    enable = lib.mkEnableOption "Nix-owned Flux bootstrap with scoped Git reconciliation";
    repository = lib.mkOption {
      type = lib.types.str;
      description = "HTTPS Git URL; credentials must not be embedded.";
    };
    branch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Branch reconciled by Flux.";
    };
    revision = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional exact Git commit for recovery.";
    };
    path = lib.mkOption {
      type = lib.types.str;
      description = "Cluster entry point in the Git source.";
    };
    suspend = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Suspend the Nix-owned root during data recovery.";
    };
    ageIdentityFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/flux/age/keys.txt";
      description = "External root-only age identity; use a string, never a Nix path literal.";
    };
    gitCredentialDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional external directory with username and password (read-only Git token) files.";
    };
  };
  config = lib.mkIf (cluster.enable && cfg.enable) {
    assertions = [
      {
        assertion = builtins.length serviceOctets == 4;
        message = "The Flux networking overlay requires an IPv4 service CIDR.";
      }
      {
        assertion = lib.hasPrefix "https://" cfg.repository && !(lib.hasInfix "@" cfg.repository);
        message = "Flux requires an HTTPS repository URL without embedded credentials.";
      }
      {
        assertion = pkgs.fluxcd.version == distribution.version;
        message = "Update the pinned Flux CLI and distribution together.";
      }
      {
        assertion =
          !(lib.hasPrefix builtins.storeDir cfg.ageIdentityFile)
          && (
            cfg.gitCredentialDirectory == null || !(lib.hasPrefix builtins.storeDir cfg.gitCredentialDirectory)
          );
        message = "Flux credentials must never be Nix store paths.";
      }
    ];
    services.k3s.manifests = {
      "30-flux-runtime".source = runtime;
      "31-flux-rbac".source = ./flux/rbac.yaml;
      "32-flux-sync".source = sync;
      "33-flux-network".source = networkPolicy;
    };
    environment.systemPackages = [
      pkgs.fluxcd
      pkgs.age
      pkgs.sops
    ];
    systemd.tmpfiles.rules = [
      "d /var/lib/flux 0700 root root -"
      "d /var/lib/flux/age 0700 root root -"
    ];
    systemd.services.flux-bootstrap = {
      description = "Provision Flux bootstrap credentials from external files";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];
      unitConfig.ConditionPathExists = [
        cfg.ageIdentityFile
        "!${cluster.recoveryHoldFile}"
      ];
      path = [
        config.services.k3s.package
        pkgs.kubectl
        pkgs.fluxcd
        pkgs.age
        pkgs.coreutils
        pkgs.jq
      ];
      script = ''
        exec ${pkgs.bash}/bin/bash ${../../scripts/provision-flux-credentials.sh} ${lib.escapeShellArg cfg.ageIdentityFile} ${
          lib.optionalString (cfg.gitCredentialDirectory != null) (
            lib.escapeShellArg cfg.gitCredentialDirectory
          )
        }
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "15s";
        UMask = "0077";
      };
    };
  };
}
