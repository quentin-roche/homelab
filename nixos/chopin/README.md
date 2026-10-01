# Chopin

NixOS on AMD x86_64 hardware, UEFI/systemd-boot, ZFS root, no swap.
The 1 Gb port `enp9s0` (MAC `B4:2E:99:C6:4C:F4`) uses DHCP; its current
management address is `192.168.1.167`. The two 10 Gb ports `enp1s0f0` and
`enp1s0f1` are unmanaged, down, and have no addresses. They are reserved for
future PCI passthrough; VFIO assignment to a VM remains to be configured.
K3s uses the separate internal address `10.44.0.1/32` on `k3s0`. Its API and
kubelet listen on that address, with local API access also available over
loopback. Kubernetes administration goes through SSH.

| File | Responsibility |
| --- | --- |
| `configuration.nix` | Host composition, locale, bootloader, state compatibility |
| `hardware-configuration.nix` | Hardware drivers and AMD microcode |
| `disk-config.nix` | GPT, 1 GiB EFI partition, ZFS root and maintenance |
| `networking.nix` | DHCP management, internal Kubernetes interface, reserved ports |
| `access.nix` / `keys/quentin.pub` | Immutable root account, public key and SSH |
| `kubernetes.nix` | Host settings for the [shared cluster module](../modules/kubernetes/README.md) |

The Samsung 970 EVO SSD is selected by its persistent model/serial device ID.
The single-disk pool `zroot` uses `ashift=12`; `zroot/nixos` mounts at `/` and
contains the Nix store, K3s state, and local-path PVC data. Dataset properties
are LZ4 compression, 128 KiB records, system attributes, POSIX ACLs, relative
access timestamps, standard synchronous writes, and deduplication off. ZFS
trims weekly and scrubs monthly. A normal rebuild never repartitions disks.

## Administrator access

Root uses Quentin's existing personal Ed25519 key. The private half stays on
the administrator's computer (currently `~/.ssh/personal`); back it up in
protected storage. Root password login is locked. SSH accepts public keys for
root only; password and keyboard-interactive authentication are disabled.
There is no `rocheque` account or sudo requirement.

```sh
ssh -i ~/.ssh/personal -o IdentitiesOnly=yes root@192.168.1.167
# On Chopin, with the repository checked out:
cd /root/homelab
nixos-rebuild build --flake "$PWD/nixos#chopin"
nixos-rebuild switch --flake "$PWD/nixos#chopin"
k3s kubectl get nodes
k3s kubectl get pods -A
```

Use the current DHCP address. A reservation on the router can keep the
management address stable without tying Kubernetes to it. SSH host keys
remain outside Git. A reinstall changes the fingerprint unless trusted
backups restore `/etc/ssh/ssh_host_*`. Losing every authorized private key
requires console recovery and a rebuild with a replacement public key.

## Verified deployment

The clean remote ZFS reinstall on 2026-10-01 passed the Kata/Calico isolation
checks, including PVC persistence across replacement of a Kata VM. Management
then moved to DHCP on the 1 Gb port and Kubernetes to its internal address;
the isolation and persistence checks passed again. A reboot confirmed the
healthy ZFS pool/root mount, trim and scrub timers, DHCP management address,
internal interface, both 10 Gb ports down without addresses, and all five
infrastructure pods Ready. The API and kubelet were unreachable at the LAN
management address.

These live checks used the configuration before the later module/Flux
reorganization. The adapted configuration preserves that deployment's disk,
access, and network settings alongside the Flux bootstrap already on `main`.
Flux credentials and live reconciliation still require their own verification.

## Install from scratch

This procedure erases the selected disk. For the live machine, first confirm a
fresh key-authenticated root connection as described above. Save protected, off-machine backups
first if existing application data or cluster identity must survive. Boot the
NixOS x86_64 installer in UEFI mode on Chopin and connect it to the LAN/internet.
The private administrator key is not needed on the installer.

```sh
# Get a reviewed revision, including its committed nixos/flake.lock.
nix-shell -p git
git clone https://github.com/quentin-roche/homelab.git
cd homelab
git checkout <reviewed-commit>
# Select the whole target disk by model/serial, not an arbitrary /dev/sda.
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/
```

Replace `<target-disk-id>` below with the verified whole-disk ID. The default device is Chopin's recorded SSD. Override it explicitly for a
replacement disk after checking the model and serial. First preview (builds
the system without formatting):

```sh
sudo nix --extra-experimental-features 'nix-command flakes' \
  run "$PWD/nixos#disko-install" -- --dry-run \
  --flake "$PWD/nixos#chopin" --disk main /dev/disk/by-id/<target-disk-id> \
  --write-efi-boot-entries
```

Then run the same command without `--dry-run` to partition, format, install the
locked NixOS system, and write its EFI boot entry. Disko installs without asking
for a root password. After success, `sudo reboot` and log in from the Mac:

```sh
ssh -i ~/.ssh/personal -o IdentitiesOnly=yes root@192.168.1.167
# On Chopin:
k3s kubectl get nodes
k3s kubectl get pods -A
```

K3s creates fresh credentials and installs Calico, Kata RuntimeClass, admission
rules, and network policies from the configuration automatically. Allow image
pulls and initial reconciliation to finish. The installer creates the declared EFI partition, ZFS pool, and root dataset.
Do not import a replacement pool together with another pool of the same name.

This definition targets Chopin's recorded hardware. For different hardware,
review the generated hardware scan, interface name, network settings, and KVM
support. It needs no private GitHub key or saved GitHub login to clone the public
repository. Personal shell files and manual Kubernetes objects are not restored
from this configuration.

## Flux application recovery

After the runtime is healthy, provision the externally backed-up age identity,
start `flux-bootstrap`, then reconcile the Git source/root. Applications and
additional services are Flux-owned, not K3s Nix manifests. Follow the complete
[recovery runbook](../../kubernetes/RECOVERY.md), which separates configuration
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
`rm /var/lib/homelab/restore-in-progress`, and start K3s.
Do not merge a fresh SQLite database with a backup or lose the original token.

If a normal update breaks networking or access, choose the previous generation
in systemd-boot at the console. Password hashes are locked by this configuration;
use the installer to mount the existing root and boot partition for rescue
rather than relying on a local password. NixOS rollback does not roll back the
Kubernetes datastore. See the [cluster guide](../modules/kubernetes/README.md)
for policy recovery and live verification requirements.
