# Chopin

NixOS configuration for Quentin's computer **chopin**.

Initial configuration copied from `/etc/nixos` on 2026-09-30.

## Machine

- SSH: `rocheque@192.168.1.82` (current LAN address)
- Current configured hostname: `nixos`
- Platform: `x86_64-linux`, AMD CPU
- NixOS state version: `26.05`

## Files

- `configuration.nix`: system settings, user account, SSH, and Nix features.
- `hardware-configuration.nix`: generated hardware and filesystem configuration.

## Repository on Chopin

The working copy is `/home/rocheque/chopin`, cloned over SSH from:

```text
git@github.com:quentin-roche/chopin.git
```

The live configuration files are symlinks into this repository:

- `/etc/nixos/configuration.nix` → `/home/rocheque/chopin/configuration.nix`
- `/etc/nixos/hardware-configuration.nix` → `/home/rocheque/chopin/hardware-configuration.nix`

The original files were backed up to `/etc/nixos.backup-chopin.SrBmds` before linking.

GitHub authentication uses the SSH key `~/.ssh/id_ed25519_github_chopin`, registered on `quentin-roche` as `rocheque@chopin`. The private key stays on Chopin.

## Edit and apply on Chopin

Git is currently available through a temporary Nix shell:

```bash
nix-shell -p git
cd ~/chopin
git pull --ff-only
# Edit configuration.nix as needed.
sudo nixos-rebuild switch
git add configuration.nix
git commit -m "Update Chopin configuration"
git push
```

The hardware configuration belongs to this computer; review it before using it on another machine.

## Temporary Codex shell

Flakes are enabled in `configuration.nix`. On Chopin:

```bash
nix shell github:NixOS/nixpkgs/nixos-unstable#codex
codex
```

Keep passwords, API keys, private keys, and authentication files outside this repository.
