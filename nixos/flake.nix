{
  description = "NixOS configurations for Quentin's homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko/v1.12.0";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
      inputs.nixos-stable.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      nixos-anywhere,
      ...
    }:
    let
      repoRoot = ../.;
      libOptionalInstaller =
        system:
        nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          disko-install = disko.packages.x86_64-linux.disko-install;
          chopin-installer =
            nixos-anywhere.inputs.nixos-images.packages.x86_64-linux.kexec-installer-nixos-stable-noninteractive;
        };
    in
    {
      apps = builtins.mapAttrs (_: packages: {
        install-chopin = {
          type = "app";
          program = "${packages.default}/bin/nixos-anywhere";
        };
      }) nixos-anywhere.packages;
      nixosModules.kubernetes = import ./modules/kubernetes;
      nixosConfigurations.chopin = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          ./chopin/configuration.nix
        ];
      };
      checks.x86_64-linux.chopin = self.nixosConfigurations.chopin.config.system.build.toplevel;
      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          dependencies = import ./modules/kubernetes/packages.nix { inherit pkgs; };
          c = self.nixosConfigurations.chopin.config;
          runtimeInputs = pkgs.writeText "chopin-runtime-inputs.json" (
            builtins.toJSON {
              assertions = builtins.all (a: a.assertion) c.assertions;
              ssh = c.services.openssh.settings;
              mutableUsers = c.users.mutableUsers;
              nodeIP = c.homelab.kubernetes.nodeIP;
              interface = c.homelab.kubernetes.interface;
              podCIDR = c.homelab.kubernetes.podCIDR;
              lanCIDR = c.homelab.kubernetes.lanCIDR;
              serviceCIDR = c.homelab.kubernetes.serviceCIDR;
              fluxSync = c.services.k3s.manifests."32-flux-sync".source.text;
              fluxNetwork = c.services.k3s.manifests."33-flux-network".source.text;
              hostSecurity = c.services.k3s.manifests."20-host-security".source.text;
              recoveryHoldFile = c.homelab.kubernetes.recoveryHoldFile;
              k3sConditions = c.systemd.services.k3s.unitConfig.ConditionPathExists;
              credentialConditions = c.systemd.services.flux-bootstrap.unitConfig.ConditionPathExists;
            }
          );
          python = pkgs.python3.withPackages (p: [
            p.pyyaml
            p.jsonschema
          ]);
        in
        libOptionalInstaller system
        // {
          validate = pkgs.writeShellApplication {
            name = "validate-homelab";
            runtimeInputs = [
              pkgs.kustomize
              pkgs.kubernetes-helm
              python
            ];
            text = ''
              exec python ${../scripts/validate.py} --flux-manifest ${dependencies.flux.install} --kubernetes-schema ${dependencies.kubernetesSchema} --calico-manifest ${dependencies.calico} --runtime-inputs ${runtimeInputs} "$@"
            '';
          };
        }
      );
      devShells = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.fluxcd
              pkgs.kustomize
              pkgs.kubernetes-helm
              pkgs.sops
              pkgs.age
              pkgs.kubectl
              pkgs.jq
              pkgs.shellcheck
              (pkgs.python3.withPackages (p: [
                p.pyyaml
                p.jsonschema
              ]))
            ];
          };
        }
      );
      checks.aarch64-darwin.gitops =
        nixpkgs.legacyPackages.aarch64-darwin.runCommand "check-gitops" { }
          ''
            ${self.packages.aarch64-darwin.validate}/bin/validate-homelab --repo ${repoRoot}
            touch "$out"
          '';
      checks.x86_64-linux.gitops = nixpkgs.legacyPackages.x86_64-linux.runCommand "check-gitops" { } ''
        ${self.packages.x86_64-linux.validate}/bin/validate-homelab --repo ${repoRoot}
        touch "$out"
      '';
      formatter = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (
        system: nixpkgs.legacyPackages.${system}.nixfmt-tree
      );
    };
}
