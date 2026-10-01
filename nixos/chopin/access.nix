{ ... }:

{
  users.mutableUsers = false;
  users.users.root.hashedPassword = "!";
  users.users.rocheque = {
    isNormalUser = true;
    description = "Quentin";
    extraGroups = [ "wheel" ];
    hashedPassword = "!";
    openssh.authorizedKeys.keyFiles = [ ./keys/quentin.pub ];
  };

  # Administrative access is possession of the SSH private key. No reusable
  # login/sudo password needs to be provisioned after a reinstall.
  security.sudo.extraRules = [
    {
      users = [ "rocheque" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
  services.openssh = {
    enable = true;
    settings = {
      AllowUsers = [ "rocheque" ];
      AuthenticationMethods = "publickey";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      PermitEmptyPasswords = false;
    };
  };
}
