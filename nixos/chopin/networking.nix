{ config, ... }:

let
  cluster = config.homelab.kubernetes;
in
{
  # Reserve this address outside the router's DHCP pool. These values also
  # appear in the Calico host policies and the CNI configuration.
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.networks."10-lan" = {
    matchConfig.Name = cluster.interface;
    address = [ "${cluster.nodeIP}/24" ];
    routes = [ { Gateway = "192.168.1.254"; } ];
    dns = [ "192.168.1.254" ];
    networkConfig.IPv6AcceptRA = true;
    linkConfig.RequiredForOnline = "routable";
  };
  services.resolved.enable = true;
}
