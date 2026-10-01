# Homelab

Declarative NixOS hosts, with dependencies pinned in `nixos/flake.lock`.

- [`nixos/chopin/`](nixos/chopin/README.md): hardware, disks, static networking, key-only
  administrator access, and reinstall/recovery instructions.
- [`nixos/modules/kubernetes/`](nixos/modules/kubernetes/README.md): reusable K3s, Calico,
  Kata VM isolation, security policies, and Nix-owned Flux bootstrap.
- [`kubernetes/`](kubernetes/README.md): Flux-managed apps/services, Kustomize/Helm, SOPS/age, and the [recovery runbook](kubernetes/RECOVERY.md).

Stage only reviewed configuration files before checking a Git flake; untracked
files are not included. Do not use `path:` flakes with a checkout containing
private material: that bypasses Git filtering and can copy ignored files into
the Nix store. All bootstrap credentials belong outside the checkout.

Run these commands from the repository root:

```sh
# Any Nix machine: evaluate every output, including the full NixOS system.
nix flake check --all-systems --no-build "$PWD/nixos"
# x86_64 Linux: build the complete host configuration.
nix build "$PWD/nixos#checks.x86_64-linux.chopin"
nix run "$PWD/nixos#validate" -- --repo "$PWD"
# Format Nix files using the locked formatter.
(cd nixos && nix fmt)
```

The flake exports `nixosConfigurations.chopin`, `nixosModules.kubernetes`, a pinned `validate` command, a development shell, and
an x86_64 Linux `disko-install` package. Keep the lock file in Git; updates are
explicit. Public SSH keys belong in Git. Passwords, private keys, kubeconfigs,
cluster tokens, and backups do not. Generated cluster credentials and
application data require protected backups; reinstalling from Git creates a
fresh cluster unless those backups are restored.
