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

## Apply on Chopin

Clone or copy this repository onto Chopin. From the repository directory:

```bash
sudo install -m 0644 configuration.nix hardware-configuration.nix /etc/nixos/
sudo nixos-rebuild switch
```

The hardware configuration belongs to this computer; review it before using it on another machine.

## Temporary Codex shell

Flakes are enabled in `configuration.nix`. On Chopin:

```bash
nix shell github:NixOS/nixpkgs/nixos-unstable#codex
codex
```

Keep passwords, API keys, private keys, and authentication files outside this repository.
