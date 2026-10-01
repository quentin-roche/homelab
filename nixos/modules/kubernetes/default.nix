{ config, lib, ... }:

{
  imports = [
    ./k3s.nix
    ./kata.nix
    ./calico.nix
    ./flux.nix
    ./platform.nix
  ];
  options.homelab.kubernetes = {
    enable = lib.mkEnableOption "K3s with Kata VM isolation and Calico policy";
    nodeName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Kubernetes node and Calico host endpoint name.";
    };
    nodeIP = lib.mkOption {
      type = lib.types.str;
      description = "Static IPv4 address of this node.";
    };
    interface = lib.mkOption {
      type = lib.types.str;
      description = "Host interface used for Calico address detection.";
    };
    lanCIDR = lib.mkOption {
      type = lib.types.str;
      description = "IPv4 LAN permitted to use SSH and DHCP.";
    };
    dnsServerCIDRs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Host DNS resolvers as IPv4/IPv6 CIDRs.";
    };
    recoveryHoldFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/homelab/restore-in-progress";
      description = "External marker that prevents K3s and Flux credential startup until restored data is ready.";
    };
    podCIDR = lib.mkOption {
      type = lib.types.str;
      default = "10.42.0.0/16";
      description = "IPv4 pod network.";
    };
    serviceCIDR = lib.mkOption {
      type = lib.types.str;
      default = "10.43.0.0/16";
      description = "IPv4 service network.";
    };
  };
}
