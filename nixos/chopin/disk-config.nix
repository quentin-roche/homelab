{ ... }:

let
  rootUUID = "59cc572c-a9a1-4cb1-84f4-9c7d7ede4d49";
  bootID = "E450D745";
in
{
  # Keep UUID mounts compatible with the existing installation. Formatting
  # recreates these identifiers. Never attach the old and new disks together.
  disko.enableConfig = false;
  disko.devices.disk.main = {
    # disko-install must receive --disk main /dev/disk/by-id/<chosen-disk>.
    device = "/dev/disk/by-id/CHOPIN_INSTALL_DISK_MUST_BE_SELECTED";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            extraArgs = [
              "-i"
              bootID
            ];
            mountpoint = "/boot";
            mountOptions = [
              "fmask=0077"
              "dmask=0077"
            ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            extraArgs = [
              "-U"
              rootUUID
            ];
            mountpoint = "/";
          };
        };
      };
    };
  };
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/${rootUUID}";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/E450-D745";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };
  swapDevices = [ ];
}
