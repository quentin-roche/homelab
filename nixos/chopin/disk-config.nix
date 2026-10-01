{ pkgs, ... }:

{
  swapDevices = [ ];

  # Stable, unique identifier used by ZFS when importing the root pool.
  networking.hostId = "6118a633";
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.devNodes = "/dev/disk/by-id";
  boot.zfs.forceImportRoot = false;

  # Keep the existing weekly TRIM policy, using the ZFS pool operation.
  services.fstrim.enable = false;
  services.zfs.trim = {
    enable = true;
    interval = "weekly";
  };
  services.zfs.autoScrub = {
    enable = true;
    interval = "monthly";
    pools = [ "zroot" ];
  };
  environment.systemPackages = with pkgs; [
    smartmontools
    nvme-cli
    fio
  ];

  disko.devices = {
    disk.system = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-Samsung_SSD_970_EVO_1TB_S5H9NS0NB82502W";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "zroot";
            };
          };
        };
      };
    };

    zpool.zroot = {
      type = "zpool";
      options = {
        ashift = "12";
        autotrim = "off";
        cachefile = "none";
      };
      # Inherited by child datasets unless explicitly overridden.
      rootFsOptions = {
        mountpoint = "none";
        compression = "lz4";
        xattr = "sa";
        acltype = "posixacl";
        atime = "on";
        relatime = "on";
        dedup = "off";
        sync = "standard";
      };
      datasets.nixos = {
        type = "zfs_fs";
        options = {
          mountpoint = "legacy";
          recordsize = "128K";
        };
        mountpoint = "/";
      };
    };
  };
}
