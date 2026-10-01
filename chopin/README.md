# Chopin

NixOS on AMD x86_64 hardware, UEFI/systemd-boot, ext4 root, no swap.
Hostname `chopin`, interface `enp1s0f1`, address `192.168.1.82/24`, gateway/DNS
`192.168.1.254`. Reserve this address outside the router's DHCP pool.

| File | Responsibility |
| --- | --- |
| `configuration.nix` | Host composition, locale, bootloader, state compatibility |
| `hardware-configuration.nix` | Hardware drivers and AMD microcode |
| `disk-config.nix` | GPT, 1 GiB EFI partition, ext4 root using the remaining disk |
| `networking.nix` | Static address and systemd-networkd; no saved NetworkManager profile |
| `access.nix` / `keys/quentin.pub` | Immutable accounts, public key, SSH and sudo |
| `kubernetes.nix` | Host settings for the [shared cluster module](../modules/kubernetes/README.md) |

## Administrator access

`rocheque` uses Quentin's existing personal Ed25519 key. Its private half stays
on the administrator's computer (currently `~/.ssh/personal`); back it up in
protected storage. Root and user password logins are locked. SSH only accepts
public keys, denies root, and disables password and keyboard-interactive
methods. `rocheque` can use passwordless sudo: access to this key grants full
administrative access. There is no login password to store or recover.

SSH host keys are generated on first boot and remain outside Git. A reinstall
changes the server fingerprint unless `/etc/ssh/ssh_host_*` is restored from a
protected backup. Verify the new fingerprint at the console before updating
`known_hosts`. Losing all authorized private keys requires the recovery console
and a rebuild with a replacement public key.

## Migrate the existing installation

The old installation uses hostname `nixos` and NetworkManager. Existing
filesystem UUIDs and Kubernetes node name are retained. This change sets the
OS hostname to `chopin`, replaces NetworkManager with a static networkd profile,
locks password logins, and renames the network guard. Keep console access for
the first activation, and verify the interface, gateway, and reserved address.

The personal key was enrolled and a fresh key-only administrative connection
verified on 2026-10-01. For a replacement host, enroll it through the existing
login or console if necessary:

```sh
ssh-copy-id -i ~/.ssh/personal.pub rocheque@192.168.1.82
ssh -i ~/.ssh/personal -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no rocheque@192.168.1.82
```

Enter any existing SSH/sudo password interactively; never put it in a command,
environment file, or Git. In the new key-authenticated session, run `sudo -v`
and `sudo -n true` to confirm administrative access before proceeding. On Chopin, with this repository checked out:

```sh
cd /home/rocheque/homelab
sudo nixos-rebuild build --flake "$PWD#chopin"
sudo nixos-rebuild test --flake "$PWD#chopin"
```

From a second terminal, verify a fresh SSH login and `sudo -n true`, then inspect
`networkctl status enp1s0f1`, `resolvectl status`, and the cluster. When verified,
make it the boot default:

```sh
sudo nixos-rebuild switch --flake "$PWD#chopin"
sudo k3s kubectl get nodes
sudo systemctl status k3s homelab-network-guard
```

The old `inet chopin_guard` nftables table can remain until reboot; it enforces
the same packet checks as `homelab_guard`. Reboot during a maintenance window
after the new generation is verified. A normal rebuild never repartitions.

## Install from scratch

This procedure erases the selected disk. For the live machine, first confirm a
fresh key-authenticated administrative connection as described above. Save protected, off-machine backups
first if existing application data or cluster identity must survive. Boot the
NixOS x86_64 installer in UEFI mode on Chopin and connect it to the LAN/internet.
The private administrator key is not needed on the installer.

```sh
# Get a reviewed revision, including its committed flake.lock.
nix-shell -p git
git clone https://github.com/quentin-roche/homelab.git
cd homelab
git checkout <reviewed-commit>
# Select the whole target disk by model/serial, not an arbitrary /dev/sda.
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/
```

Replace `<target-disk-id>` below with the verified whole-disk ID. The configured
device is deliberately a nonexistent placeholder, so the installer requires
an explicit disk selection. First preview (builds the system without formatting):

```sh
sudo nix --extra-experimental-features 'nix-command flakes' \
  run "$PWD#disko-install" -- --dry-run \
  --flake "$PWD#chopin" --disk main /dev/disk/by-id/<target-disk-id> \
  --write-efi-boot-entries
```

Then run the same command without `--dry-run` to partition, format, install the
locked NixOS system, and write its EFI boot entry. Disko installs without asking
for a root password. After success, `sudo reboot` and log in from the Mac:

```sh
ssh -i ~/.ssh/personal -o IdentitiesOnly=yes rocheque@192.168.1.82
# On Chopin:
sudo -n k3s kubectl get nodes
sudo -n k3s kubectl get pods -A
```

K3s creates fresh credentials and installs Calico, Kata RuntimeClass, admission
rules, and network policies from the configuration automatically. Allow image
pulls and initial reconciliation to finish. The installer recreates the
original filesystem UUIDs for compatibility with existing rebuilds; do not
attach both original and replacement disks to the same running system.

This definition targets Chopin's recorded hardware. For different hardware,
review the generated hardware scan, interface name, network settings, and KVM
support. It needs no private GitHub key or saved GitHub login to clone the public
repository. Personal shell files and manual Kubernetes objects are not restored
from this configuration.

## Flux application recovery

After the runtime is healthy, provision the externally backed-up age identity,
start `flux-bootstrap`, then reconcile the Git source/root. Applications and
additional services are Flux-owned, not K3s Nix manifests. Follow the complete
[recovery runbook](../kubernetes/RECOVERY.md), which separates configuration
recovery from cluster datastore and persistent-data recovery. Do not start
stateful writers before their data and volume identities are restored.

## Restore data and recover access

Git reproduces the system and managed manifests. It does not reproduce mutable
data. Quiesce application writes before stopping K3s; pods/VMs can keep running
after the service stops. Back up `/var/lib/rancher/k3s/server` (including SQLite,
server token, and encryption keys) and `/var/lib/rancher/k3s/storage` together,
plus any external volumes, into root-only storage and encrypt off-machine copies.
Optionally protect SSH host keys and administrator home data too. No off-machine
backup destination is configured.

For restoring a cluster, use the same locked K3s version as the backup. Before
first boot, create `touch /tmp/restore-in-progress` on the installer and add
`--extra-files /tmp/restore-in-progress /var/lib/homelab/restore-in-progress`
to the installation command. Nix's startup conditions hold K3s and Flux
credentials until this marker is removed. Disko's installed root is
`/mnt/disko-install-root` during installation and is unmounted when it returns.
After booting with K3s held, mount the backup, restore both server and storage
directories with ownership/modes intact, remove the marker with
`sudo rm /var/lib/homelab/restore-in-progress`, and start K3s.
Do not merge a fresh SQLite database with a backup or lose the original token.

If a normal update breaks networking or access, choose the previous generation
in systemd-boot at the console. Password hashes are locked by this configuration;
use the installer to mount the existing root and boot partition for rescue
rather than relying on a local password. NixOS rollback does not roll back the
Kubernetes datastore. See the [cluster guide](../modules/kubernetes/README.md)
for policy recovery and live verification requirements.
