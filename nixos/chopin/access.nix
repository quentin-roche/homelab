{ ... }:

{
  users.mutableUsers = false;
  users.users.root.hashedPassword = "!";
  users.users.root.openssh.authorizedKeys.keyFiles = [ ./keys/quentin.pub ];
  security.sudo.enable = false;
  services.openssh = {
    enable = true;
    settings = {
      AllowUsers = [ "root" ];
      AuthenticationMethods = "publickey";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
      PermitEmptyPasswords = false;
    };
  };
}
