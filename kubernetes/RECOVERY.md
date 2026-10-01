# Recover Chopin

Configuration recovery rebuilds NixOS and reconciles Kubernetes objects from a
reviewed Git revision. Data recovery restores the cluster datastore, encryption
material, persistent volumes, external services, and application state from
protected backups. Git, Flux, and SOPS do not back up those data.

## Protect prerequisites before a failure

| Material | Where it belongs | Recovery requirement |
| --- | --- | --- |
| Administrator SSH private key | Administrator computer/protected backup, never Git | Matches the public key in `nixos/chopin/keys/quentin.pub` |
| age private identity | Protected backup; root-only `/var/lib/flux/age/keys.txt` on Chopin | Must decrypt secrets at the selected Git/backup revision |
| Public age recipient and encrypted Secrets | Git | Recipient goes in `.sops.yaml`; no plaintext values |
| Git credentials | None for current public HTTPS; external read-only token files if private | Restore separately and configure the Nix credential-directory string |
| Registry/chart credentials, TLS keys, app passwords | SOPS-encrypted Git Secrets; protected external originals if needed | Reconcile and verify access to corresponding external services |
| K3s server directory | Encrypted off-machine backup | Includes SQLite datastore, token, and secrets-encryption material; restore together |
| K3s storage and external volumes | Consistent encrypted backups or storage-native backups | Match application state and datastore/PV identity |
| SSH server host keys | Optional protected `/etc/ssh/ssh_host_*` backup | Restoring preserves the fingerprint; otherwise verify new keys at the console |

Quiesce writers and make application-native database backups. Stopping K3s alone
can leave containers/VMs writing. Take a consistent backup of
`/var/lib/rancher/k3s/server` and `/var/lib/rancher/k3s/storage` together, with
ownership/modes intact. Back up any storage outside these paths separately.
Record the Git revision, `nixos/flake.lock`, K3s/Flux versions, volume paths, restore
commands, and external dependencies alongside the encrypted backup. Keep copies
off Chopin and test restore regularly. No off-machine destination or retention
schedule has been configured by this repo cleanup.

## 1. Verify administrative access and choose a recovery mode

The personal key was enrolled and a fresh key-only administrative connection
verified on 2026-10-01. Before any later migration, confirm a **new** key-only SSH
root session. Follow the [access checks](../nixos/chopin/README.md).
Do not rely on an already-open password-authenticated session. If access is
lost, use the NixOS installer/console to mount and repair the existing system.

Do not format/reinstall the live machine or switch it to key-only SSH until a
fresh key-authenticated administrative connection has succeeded. Nothing in
this cleanup runs disk formatting, reinstall, or live activation.
A destructive reinstall needs an explicitly selected target disk and saved
backups. Use the [host installation procedure](../nixos/chopin/README.md), at the
reviewed configuration revision, only when reinstalling is actually intended.

Choose one of these data paths before installing:

- **New cluster/configuration only:** regenerate K3s identity and cluster state,
  then reconcile stateless workloads. Stateful applications need a separate
  volume/data restore plan before they start.
- **Preserve cluster identity/datastore:** restore the entire K3s server/storage
  pair before K3s ever starts on the new install. Use the locked K3s version that
  created the backup. Upgrade only after a successful restore.

For a stateful recovery, set `homelab.kubernetes.flux.suspend = true;` in the
recovery checkout's `nixos/chopin/kubernetes.nix` **before** installing. This is a
Nix-owned root flag; keep it suspended until data is ready. Set `flux.revision`
to the exact reviewed Git commit if recovery must not follow new `main` changes.
Do not write a real secret into the recovery checkout. Existing Pods and
HelmReleases can continue independently of a suspended root, so a restored full
datastore must be paired with restored volume data before K3s starts. Root
suspension alone is not a workload stop.

## 2. Reinstall NixOS and restore state before startup when required

The Disko installer creates the declared GPT, EFI filesystem, ZFS pool, and
root dataset, then installs the pinned host closure. A normal rebuild does
not partition disks. Do not import two pools named `zroot` together.
Preserve/restore SSH host keys only from trusted backups.

For a full datastore restore, create a recovery marker on the live installer:

```sh
touch /tmp/restore-in-progress
```

Add `--extra-files /tmp/restore-in-progress /var/lib/homelab/restore-in-progress`
to the Disko installation command. Nix declares startup conditions for K3s and
Flux credentials that hold both services while this marker exists. Do not place
manual masks in `/etc/systemd/system`, which Nix manages. Mount the protected backup
and restore `/var/lib/rancher/k3s/server` and `/var/lib/rancher/k3s/storage` with
original ownership/modes. Do not merge a fresh SQLite database with the backup;
restore the matching token/encryption material. Restore external volumes too.
The backup itself must be consistent; this does not repair a corrupt backup.

For configuration recovery with new cluster identity and old application data,
keep root Flux reconciliation suspended. Start K3s and reconstruct the intended
PVC/PV bindings with the exact volume identity/path and reclaim policy before
starting the applications. K3s local-path volumes use generated directories
and node-bound PVs; copying files into `/var/lib/rancher/k3s/storage` is not
sufficient if newly generated PVCs point elsewhere. Use the application's
storage/database restore procedure. Do not let a blank volume overwrite an
external backup.

## 3. Start and verify the Nix-owned cluster runtime

For a full datastore recovery, remove only the recovery marker after all
matched data is restored:

```sh
rm /var/lib/homelab/restore-in-progress
systemctl start k3s
```

For a fresh install without the marker, K3s starts automatically. Verify at the
console or through a newly authenticated SSH connection:

```sh
k3s kubectl get nodes
k3s kubectl get pods -n kube-system
k3s kubectl get runtimeclass kata-qemu
k3s kubectl get globalnetworkpolicies.crd.projectcalico.org
systemctl status k3s homelab-network-guard
nft list table inet homelab_guard
```

Calico, the firewall guard, admission rules, and namespaces must be healthy.
Wait for their initial reconciliation/image downloads. Verify Kata startup,
application DNS, admission enforcement and blocked node/LAN/internet traffic
before resuming workloads. Do not bypass the guard or admission rules as a
recovery shortcut.

## 4. Restore external bootstrap credentials and verify Flux

Restore the externally backed-up age identity to `/var/lib/flux/age/keys.txt`,
owned by root with mode 0600. Confirm its public recipient matches the SOPS
files at the selected Git revision. Restore optional private Git token files
separately, plus credentials for external data/services. Run:

```sh
systemctl restart flux-bootstrap
systemctl status flux-bootstrap
env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux check
env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux get sources all
```

Nix already installed the pinned Flux controllers and root objects. The helper
only provisions external credentials and checks dependencies. It does not
write bootstrap manifests to Git. Confirm Flux controllers actually run in
Kata and that the source has the expected revision. Missing private material
cannot be recovered from the public recipient or ciphertext alone.

## 5. Reconcile definitions, then verify restored applications

For stateless configuration recovery, leave the Nix root `suspend` flag false.
For a stateful recovery, finish the application's storage/backup restore while
writers are stopped, then set the Nix root `suspend = false;` and rebuild the
already installed system. Restore from a full datastore only after matching
storage is in place. Application-specific scale/suspend controls belong in the
recovery Git overlay; a root suspension does not stop existing Pods or prevent
independent Helm reconciliation.

```sh
env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux reconcile source git homelab
env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux reconcile kustomization cluster --with-source
env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux get kustomizations
env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux get helmreleases
k3s kubectl get pods -n applications
k3s kubectl get pvc,pv -A
```

One root Kustomization reconciles the selected applications and services. Check
Secret decryption without printing values, application health, database/data
integrity, volume bindings, and isolation. Verify LAN/API restrictions and a
fresh key-authenticated administrator session. A Ready Flux object proves
reconciliation, not that the recovered database or files are correct.

After successful validation, remove the temporary recovery pin/suspension in a
reviewed change and return to the intended branch. Keep the tested backup until
new off-machine backups and a restore check succeed. NixOS rollback changes the
OS generation; it does not roll back Flux inventory, Kubernetes objects, the
SQLite datastore, passwords in external services, or application volumes.
