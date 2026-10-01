# Applications through Flux

There are two owners: **NixOS starts the cluster; Flux manages applications.**
NixOS installs K3s, Kata, Calico, essential policies, namespaces, scoped RBAC,
and Flux 2.9.5 from pinned inputs. Flux reads this public repository's `main`
branch and applies one entry point: `kubernetes/clusters/chopin/kustomization.yaml`.
Applications change after Git reconciliation, without rebuilding NixOS.

Calico and Kata stay in Nix because Flux uses them to start. The startup order
is host/K3s → Calico and essential policies → Kata-backed Flux → applications.
See the [runtime guide](../modules/kubernetes/README.md) for the three Nix files
and their responsibilities. Helm is available for additional services and apps.

The entry point starts empty. Add reusable definitions under `apps/` and
additional services under `infrastructure/`, then select them in the entry point:

```yaml
resources:
  - ../../apps/my-app
  - ../../infrastructure/my-service
```

There are no demo workloads or child reconciliation chains. Use ordinary
Kustomize resources or a version-pinned HelmRelease. Set namespaces explicitly.

## Ownership and permissions

| Owner | Resources |
| --- | --- |
| NixOS | Host, disks, SSH, K3s/containerd, Kata, Calico, essential isolation |
| NixOS | Namespaces, RuntimeClass, admission, RBAC, Flux controllers/CRDs/network access |
| NixOS | GitRepository `homelab`, Kustomization `cluster`, external credential provisioning |
| Flux | Selected applications/services, Helm definitions/releases, encrypted application Secrets |

One `flux-reconciler` account applies workloads in `applications` and
`platform-services`, and Helm definitions in `flux-system`. It cannot change
namespaces, RBAC, CRDs, RuntimeClasses, admission or Calico global policies.
These are trusted Git administrator scopes, not separate tenant boundaries.
Controllers watch only `flux-system`; impersonation is limited to this account.
Cross-namespace source references and Kustomize remote bases are disabled.
The only cluster-level grant is `HEAD /livez/ping` for API health checks.

Flux pods use Kata and restricted Pod Security without an admission exemption.
Calico explicitly permits API access, internal artifacts and node probes. Only
source-controller can fetch public IPv4 HTTPS; private/LAN/node/pod/service
ranges are excluded. DNS goes through CoreDNS. Applications do not inherit
Flux's network permissions.

Nix already installs Flux: do not run `flux bootstrap github` or manually apply
Flux-owned apps. K3s does not delete retired Nix objects automatically; retire
those explicitly during migration. Flux prunes removed application objects.
`deletionPolicy: Orphan` protects against root deletion, not normal pruning.
Protect PVCs with `kustomize.toolkit.fluxcd.io/prune: disabled`, an appropriate
PV reclaim policy, and backups.

## External credentials and application secrets

The Nix-owned `flux-bootstrap` service runs the one credential helper,
`scripts/provision-flux-credentials.sh`. It provisions Kubernetes Secrets from
protected external files; it does not install Flux or depend on a local checkout.

```sh
sudo install -d -m 0700 /var/lib/flux/age
sudo install -m 0600 /protected-backup/chopin.agekey /var/lib/flux/age/keys.txt
sudo systemctl restart flux-bootstrap
sudo systemctl status flux-bootstrap
```

The helper validates ownership/mode/key validity, waits for Flux and reapplies
the Secret safely. It runs on boot when the identity exists, and is held during
data restoration. Back up the private identity off-machine. Never put it in Git,
a Nix path literal or the Nix store, enable tracing, or dump the Secret.
No Git credential is needed for this public repository. If it becomes private,
supply external root-only `username` and `password` token files and set the
string option `homelab.kubernetes.flux.gitCredentialDirectory`.

`.sops.yaml` deliberately has no age recipient yet. Add only the public
`age1...` recipient before committing encrypted application Secrets. Generate
and store its private identity outside the checkout and back it up separately.

```sh
# Plaintext input stays outside Git; only ciphertext enters the checkout.
if sops --encrypt --filename-override kubernetes/apps/my-app/secret.sops.yaml \
  /protected-location/secret.yaml > /protected-location/secret.sops.yaml; then
  install -m 0600 /protected-location/secret.sops.yaml kubernetes/apps/my-app/secret.sops.yaml
fi
```

Select the encrypted file in the app's Kustomization. Never put passwords in
Helm values or plaintext secretGenerator inputs. Helm valuesFrom Secrets also
need encryption and explicitly granted namespace permissions. Retain old age
identities needed for backups; rewrap ciphertext and provision the new identity
before retiring the old one. Rewrapping does not rotate application passwords.

## Operate and validate

After publishing reviewed changes to `main`, on Chopin:

```sh
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux reconcile kustomization cluster --with-source
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux get kustomizations
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux get helmreleases
sudo k3s kubectl get pods -A
```

From a reviewed checkout using Git-filtered Nix sources:

```sh
nix flake check --all-systems --no-build
nix run .#validate -- --repo "$PWD"
nix build .#checks.aarch64-darwin.gitops  # Apple Silicon
# Linux: nix build .#checks.x86_64-linux.chopin .#checks.x86_64-linux.gitops
nix develop --command shellcheck scripts/provision-flux-credentials.sh modules/kubernetes/verify-isolation.sh
```

Validation renders Kustomize and checks pinned schemas, ownership, scoped RBAC,
Kata/restricted settings, network access, secret hygiene and recovery conditions.
Selected Helm releases also need their pinned chart artifact supplied with
`--helm-chart <release-name>=<artifact-path>`; add a checksum-pinned fetchurl to
the Nix validation wrapper for CI. Chart output and post-renderer patches are
validated too. Empty configuration is valid.

Live checks remain necessary for traffic, admission, guest startup and production
decryption. Git recovers configuration, not persistent data. Follow the
[recovery runbook](RECOVERY.md) and [host guide](../chopin/README.md).
