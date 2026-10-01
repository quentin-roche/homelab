{ pkgs, ... }:

{
  # Enable networking
  networking.networkmanager.enable = true;
  # Only use explicitly configured wired profiles; unused ports have no DHCP.
  networking.networkmanager.settings.main.no-auto-default = "*";
  # Reserve the two 10 Gb ports for future PCI passthrough.
  networking.networkmanager.unmanaged = [
    "interface-name:enp1s0f0"
    "interface-name:enp1s0f1"
  ];
  systemd.services.NetworkManager.postStart = ''
    for task_interface in enp1s0f0 enp1s0f1; do
      if ${pkgs.iproute2}/bin/ip link show dev "$task_interface" >/dev/null 2>&1; then
        ${pkgs.iproute2}/bin/ip -4 route flush dev "$task_interface"
        ${pkgs.iproute2}/bin/ip -6 route flush dev "$task_interface"
        ${pkgs.iproute2}/bin/ip address flush dev "$task_interface"
        ${pkgs.iproute2}/bin/ip link set dev "$task_interface" down
      fi
    done
  '';
  networking.networkmanager.ensureProfiles.profiles.chopin-lan = {
    connection = {
      id = "chopin-lan";
      type = "ethernet";
      interface-name = "enp9s0";
      autoconnect = true;
    };
    ipv4.method = "auto";
    ipv4.may-fail = false;
    ipv6.method = "auto";
  };
  networking.firewall.interfaces.enp9s0.allowedUDPPorts = [ 68 ];
  # Internal Kubernetes address, independent of the LAN's DHCP lease.
  networking.networkmanager.ensureProfiles.profiles.chopin-k3s = {
    connection = {
      id = "chopin-k3s";
      type = "dummy";
      interface-name = "k3s0";
      autoconnect = true;
    };
    ipv4 = {
      method = "manual";
      address1 = "10.44.0.1/32";
      never-default = true;
    };
    ipv6.method = "disabled";
  };

}
