{
  description = "NixOS configurations for Quentin's homelab";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }: {
    nixosConfigurations.chopin = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./chopin/configuration.nix ];
    };
  };
}
