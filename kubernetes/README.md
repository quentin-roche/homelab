# Kubernetes desired state

NixOS installs the runtime and Flux 2.9.5. Flux reconciles this directory from
`https://github.com/quentin-roche/homelab.git`, branch `main`, starting at
`clusters/chopin/`. Changes must reach that branch before the cluster can see
them. The Git source includes only `kubernetes/`; it does not apply Nix files.

- `apps/`: reusable application definitions. `web/` is a stateless Kustomize
  workload running in Kata, without an API token or external exposure.
- `infrastructure/`: reusable additional services. `podinfo/` is a stateless
  diagnostic service using Helm chart **6.15.0**, an exact version, with Kata
  and restricted security settings applied by a Helm post-renderer.
- `clusters/chopin/`: selected definitions and reconciliation order for Chopin.
  The root installs child Flux Kustomizations; infrastructure must be ready
  before applications reconcile. Definitions can be selected by another host's
  cluster directory without copying the runtime module.

These starter workloads contain no persistent data or application secrets.
Remove/replace them in the cluster overlays when adding real applications.
Neither service is exposed to the LAN. Administrator port-forward access is
available; default-deny still governs ordinary workload traffic.

## Ownership

| Owner | Resources |
| --- | --- |
| Nix | Disk, bootloader, static network, accounts, SSH, K3s, containerd, Kata, Calico |
| Nix | RuntimeClass, admission policy/binding, final deny, host endpoint/policy, nftables guard |
| Nix | `applications`, `default`, `platform-services`, and `flux-system` namespaces; their default service accounts |
| Nix | Flux CRDs, controllers, controller service accounts, source-controller Service, all Flux bootstrap RBAC and its Calico allow policy |
| Nix | `GitRepository/flux-system/homelab` and root `Kustomization/flux-system/cluster` |
| Nix runtime credential helper | `Secret/flux-system/sops-age` and optional `flux-git-auth`, from external protected files |
| Flux | Child Kustomizations `infrastructure` and `apps`, HelmRepository/HelmRelease, application objects, Helm-generated resources and release-storage Secrets |
| Flux | SOPS-encrypted application Secrets after decryption in memory |

No Flux path contains the Flux installer, root source/sync objects, namespace
bootstrap, or essential isolation policies. Do not run `flux bootstrap github`
or commit `gotk-components.yaml` here: it would introduce a second owner and
restore upstream cluster-admin permissions. Upgrade Flux through Nix and the
pinned distribution/checks together. Do not use Nix manifests for applications
or manually apply resources that Flux owns.

The ownership validator compares the connected Kustomize/Helm graph to the Nix
runtime resources and reserves the bootstrap names. K3s does not delete old
objects simply because a Nix manifest disappears; remove retired Nix objects
explicitly during a reviewed migration. Flux pruning does remove objects absent
from its desired state. Reconciliation objects use `deletionPolicy: Orphan` for
accidental deletion; this does not disable normal pruning. Mark important PVCs
with `kustomize.toolkit.fluxcd.io/prune: disabled` and use appropriate PV reclaim
policies. Those safeguards do not replace backups.

## Flux permissions and network access

All three Flux controller pods use `kata-qemu`; `flux-system` remains subject to
the existing admission policy, Pod Security restricted, and Calico final deny.
They do not receive an admission exemption. Each controller VM consumes the
RuntimeClass overhead plus its workload resources; check available capacity.

Controllers watch only `flux-system`. Kustomize and Helm reject cross-namespace
source references, use an unprivileged default service account unless one is
explicitly named, and Kustomize rejects remote bases. The reconcilers can
impersonate only the three declared service accounts in `flux-system`:

| Reconciler | Apply permissions |
| --- | --- |
| `flux-orchestrator` | Child Flux Kustomizations in `flux-system` |
| `flux-infrastructure` | Helm definitions in `flux-system`; workload and Helm storage objects in `platform-services` |
| `flux-apps` | Workload objects in `applications`; Helm definitions in `flux-system` for future application charts |

Controller roles cover Flux CRs/status, events, leases, ConfigMaps, and reads of
Secrets/service accounts in `flux-system`. The only cluster-level permission is
`HEAD /livez/ping` for API health checking. No reconciler gets cluster-admin,
permission to change RuntimeClasses/admission/Calico global policies, namespaces,
RBAC, or CRDs. Kubernetes's standard authenticated API discovery remains in use.
Adding a service that needs cluster-level objects requires a reviewed Nix RBAC
extension and an explicit ownership decision, not an automatic privilege grant.
Git write access is administrative access within the allowed workload scopes;
keep the reconciled branch protected and untrusted users away from it.

Nix installs explicit Calico rules before order 1000's final deny:

- Controllers can reach the Kubernetes API at the node's TCP 6443 and service
  IP's TCP 443. Both workload egress and host ingress allow this flow.
- Flux peers can fetch source-controller artifacts on TCP 9090; both directions
  are declared. Node health probes can reach TCP 9440/9090.
- Only source-controller may use public IPv4 HTTPS, for Git and Helm/OCI sources.
  Private, loopback, link-local, CGNAT, multicast, LAN, node, pod, and service ranges are
  excluded. This deliberately allows dynamic public GitHub/CDN addresses; it
  is not a DNS-name allowlist. Use an explicit proxy/egress gateway if tighter
  destination control is required.
- DNS uses the existing CoreDNS-only allowance. Other application namespaces
  do not inherit Flux's permissions. Source protocols requiring SSH, HTTP, or
  a private repository endpoint need a reviewed network change first.

## Bootstrap after NixOS installation

The Nix module installs checksum-pinned upstream CRDs and exactly three
controllers: source, kustomize, and helm. It strips the upstream permissive
NetworkPolicies/cluster-admin bindings and applies our declared RBAC instead.
No network bootstrap script installs a moving `latest` release. The CLI version
from `flake.lock` must equal the distribution version or Nix evaluation fails.

On Chopin, supply the externally backed-up age identity through protected
storage, without copying it into the checkout or referencing it as a Nix path:

```sh
sudo install -d -m 0700 /var/lib/flux/age
sudo install -m 0600 /path/to/protected-backup/chopin.agekey /var/lib/flux/age/keys.txt
sudo systemctl start flux-bootstrap
sudo systemctl status flux-bootstrap
```

`flux-bootstrap` is a Nix oneshot service. It is skipped until the external file
exists, waits for the Flux CRDs, validates the age identity/permissions, creates
the decryption Secret through a pipe, then waits for controller availability.
It runs again on boot when the identity exists. After replacing credentials,
use `sudo systemctl restart flux-bootstrap`. There is no secret in its Nix
script or the Nix store. Do not enable shell tracing or dump the Secret.

If the repository becomes private, provision root-only `username` and
`password` files in an external directory (the password file contains a scoped
read-only Git token). Set the **string** option
`homelab.kubernetes.flux.gitCredentialDirectory = "/var/lib/flux/git-auth";`
and rebuild. The Nix helper creates `flux-git-auth`; no private Git credential
is needed for the current public HTTPS repository. A GitHub write token is not
needed by the controllers; the administrator's existing Git access publishes
reviewed changes separately.

For operators on Chopin, use the root-only kubeconfig locally:

```sh
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux check
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux reconcile source git homelab
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux reconcile kustomization cluster --with-source
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux get kustomizations
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux get helmreleases
sudo k3s kubectl get pods -n applications
sudo k3s kubectl get pods -n platform-services
```

The Nix root `suspend` flag must be false to reconcile. Missing decryption
material, insufficient RAM, denied image pulls, or unavailable Git/chart sources
will leave reconciliation NotReady; inspect conditions and controller logs.
Do not weaken the isolation policies to make bootstrap pass.

## Application secrets with SOPS and age

`.sops.yaml` currently has an empty public age recipient. This intentionally
prevents encryption until the actual recipient is supplied. No application
Secret is committed. Set only its public `age1...` recipient in `.sops.yaml`;
back up the corresponding private identity separately. If creating an identity,
run `age-keygen -o /protected/location/chopin.agekey` outside this checkout and
copy only `age-keygen -y /protected/location/chopin.agekey` into `.sops.yaml`.
Protect the identity before provisioning it on Chopin.

Use the locked tools with `nix develop`. Prepare plaintext only in protected
storage outside the repository, then encrypt to the target filename so SOPS
selects the creation rule. `data` and `stringData` are encrypted; non-secret
Kubernetes metadata stays readable.

```sh
# The input filename is external to the checkout. Never git-add that input.
if sops --encrypt --filename-override kubernetes/apps/my-app/secret.sops.yaml \
  /protected/location/secret.yaml > /protected/location/secret.sops.yaml; then
  install -m 0600 /protected/location/secret.sops.yaml kubernetes/apps/my-app/secret.sops.yaml
fi
```

Add the encrypted file to the app's Kustomization and select that app in the
cluster overlay. Review the output for `ENC[...]` values and SOPS metadata,
then run validation before committing. Never use a Kustomize `secretGenerator`
with plaintext files or put secret values into HelmRelease `values`. For Helm,
use an encrypted Secret and `valuesFrom` (in the HelmRelease's namespace) or a
chart's existing-Secret reference. Extend scoped RBAC if the chosen namespace
requires it. Every Flux Kustomization in this graph explicitly references
`sops-age` for decryption. The private key is a runtime bootstrap credential,
not an encrypted Git Secret dependent on itself.

Key rotation needs both identities during transition: decrypt with the old
identity, set the new public recipient, run SOPS `updatekeys` for encrypted
files, publish the rewrapped ciphertext, and provision the new private identity
before retiring the old one. Keep identities needed to recover old backups or
Git revisions. Age encryption does not rotate the application's actual password;
rotate that credential in the application as well.

## Validation

```sh
nix flake check --all-systems --no-build "$PWD"
nix run "$PWD#validate" -- --repo "$PWD"
# Linux builds the complete host and the GitOps checks; macOS builds GitOps only.
nix build "$PWD#checks.x86_64-linux.chopin" "$PWD#checks.x86_64-linux.gitops"
# On Apple Silicon:
nix build "$PWD#checks.aarch64-darwin.gitops"
nix develop --command shellcheck scripts/bootstrap-flux.sh modules/kubernetes/verify-isolation.sh
```

Validation uses checksum-pinned Flux manifests, Kubernetes 1.35 API schemas,
and the exact Helm chart; it needs no cluster credentials or private identities.
It builds Kustomize layers and Helm with the actual post-renderer, checks Flux/Calico
CR schemas/dependencies, RBAC scopes, ownership collisions, restricted/Kata pod
contexts, network exceptions, and plaintext/key hygiene. The empty SOPS recipient
is reported; adding encrypted Secrets without configuring it is an error.
Calico policy traffic and Kubernetes admission CEL require live integration
checks. Offline validation does not prove image pulls, VM startup, source
reconciliation, production-key decryption, successful reinstall, or data restore.
See the [recovery runbook](RECOVERY.md) and [host guide](../chopin/README.md).

References: [Flux authorization](https://fluxcd.io/flux/installation/configuration/multitenancy/),
[Flux SOPS decryption](https://fluxcd.io/flux/components/kustomize/kustomizations/#decryption),
[Helm post-renderers](https://fluxcd.io/flux/components/helm/helmreleases/#post-renderers),
[SOPS age encryption](https://getsops.io/docs/#encrypting-using-age).
