{ ... }:

{
  imports = [ ../modules/kubernetes ];
  homelab.kubernetes = {
    enable = true;
    flux = {
      enable = true;
      repository = "https://github.com/quentin-roche/homelab.git";
      path = "./kubernetes/clusters/chopin";
      # External root-only file; never use a Nix path literal here.
      ageIdentityFile = "/var/lib/flux/age/keys.txt";
    };
    nodeIP = "10.44.0.1";
    interface = "k3s0";
    lanCIDR = "192.168.1.0/24";
    dnsServerCIDRs = [
      "192.168.1.254/32"
      "fd0f:ee:b0::1/128"
    ];
  };
}
