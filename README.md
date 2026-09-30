# Homelab

Declarative NixOS configurations for the homelab. The flake currently defines
one host, Chopin.

| Path | Purpose |
| --- | --- |
| `flake.nix` and `flake.lock` | Host entry points and pinned Nixpkgs input |
| [`chopin/configuration.nix`](chopin/configuration.nix) | Chopin's base system and LAN configuration |
| [`chopin/kubernetes.nix`](chopin/kubernetes.nix) | K3s, Kata networking, host guard, and declared workloads |
| [`chopin/tailscale/`](chopin/tailscale/) | Headscale, Tailscale sidecar, enrollment, and central policy |
| [`chopin/README.md`](chopin/README.md) | Rebuild steps, architecture, security limits, and diagnostics |

On Chopin, rebuild the declared system with:

```sh
sudo nixos-rebuild switch --flake path:/home/rocheque/homelab#chopin
```

The web application in `chopin/examples/application.yaml` is currently included
in the declared K3s manifests as a smoke-test workload. See the
[Chopin guide](chopin/README.md) before adding workloads or changing network
policy.
