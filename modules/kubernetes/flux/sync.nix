{
  pkgs,
  lib,
  cfg,
}:

pkgs.writeText "flux-sync.json" (
  builtins.toJSON {
    apiVersion = "v1";
    kind = "List";
    items = [
      {
        apiVersion = "source.toolkit.fluxcd.io/v1";
        kind = "GitRepository";
        metadata = {
          name = "homelab";
          namespace = "flux-system";
          labels."homelab/owner" = "nix";
        };
        spec = {
          interval = "1m";
          url = cfg.repository;
          ref = if cfg.revision == null then { branch = cfg.branch; } else { commit = cfg.revision; };
          ignore = "/*\n!/kubernetes\n";
        }
        // lib.optionalAttrs (cfg.gitCredentialDirectory != null) { secretRef.name = "flux-git-auth"; };
      }
      {
        apiVersion = "kustomize.toolkit.fluxcd.io/v1";
        kind = "Kustomization";
        metadata = {
          name = "cluster";
          namespace = "flux-system";
          labels."homelab/owner" = "nix";
        };
        spec = {
          interval = "5m";
          retryInterval = "30s";
          path = cfg.path;
          sourceRef = {
            kind = "GitRepository";
            name = "homelab";
          };
          serviceAccountName = "flux-reconciler";
          prune = true;
          deletionPolicy = "Orphan";
          suspend = cfg.suspend;
          timeout = "5m";
          decryption = {
            provider = "sops";
            secretRef.name = "sops-age";
          };
        };
      }
    ];
  }
)
