# Chopin: Kubernetes, Kata, and Calico

Chopin (`192.168.1.82`, SSH user `rocheque`) runs a single-node K3s cluster
called `chopin`. The existing NixOS installation, accounts, disk layout, and
SSH authentication are preserved. The OS hostname remains `nixos`.

## What is enforced

- K3s comes from the locked Nixpkgs input; deployed version: `v1.35.8+k3s1`.
- Kata 4.2.0's checksum-pinned static Rust runtime runs QEMU with KVM. Each
  application **pod** has its own VM; containers in the same pod share that VM.
- Calico Open Source 3.32.2 enforces policy on the host, outside the guest.
  Pod addresses are `10.42.0.0/16`; service addresses are `10.43.0.0/16`.
  Flannel and K3s's network-policy controller are disabled.
- All application namespaces, including newly created ones, have an explicit
  final ingress/egress deny policy. The only default application egress is
  TCP/UDP DNS to CoreDNS. Internet, LAN, other pods, the node, and Kubernetes
  API access require explicit allow rules.
- Admission requires `runtimeClassName: kata-qemu` outside the infrastructure
  namespaces. It rejects host namespaces, host paths, host ports, privileged
  containers, device requests, extra networks, IP spoofing annotations, and
  Kata configuration overrides. `applications` and `default` also enforce
  Kubernetes's restricted Pod Security Standard.
- A separate nftables guard starts before K3s. New pod packets must carry
  Calico's host-side approval mark, including while Calico is starting.
  Established/related connections retain the normal stateful behavior.
- SSH is allowed from `192.168.1.0/24`. The Kubernetes API and kubelet are not
  exposed to LAN clients. Infrastructure pods can reach the API and kubelet
  only after Calico approves their traffic.
- Chopin has a wildcard Calico HostEndpoint and an explicit host policy.
  Host egress permits cluster traffic, the router's DNS, HTTP/HTTPS for image
  pulls and updates, NTP, DHCP, and ICMP/ICMPv6. Application egress does **not**
  inherit these host allowances. The node policy covers IPv4 and IPv6;
  pod networking is IPv4 only.
- Kubernetes Secrets encryption is enabled. Administrative kubeconfig and
  cluster credentials remain on Chopin with root-only access.

The trusted base is the host, KVM, QEMU, virtiofsd, Kata, and the Kubernetes/
Calico administrators. VM isolation reduces the shared-kernel risk; it is
not a guarantee against hypervisor or runtime vulnerabilities. Keep both
the host and the bundled guest/runtime patched. System pods in `kube-system`
use the ordinary runtime because the networking and storage components need
host access. Never place untrusted workloads in the infrastructure namespaces
or grant their users permission to deploy there.

## Operate the cluster

On Chopin:

```sh
cd /home/rocheque/homelab
sudo nixos-rebuild switch --flake path:.#chopin
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A
sudo k3s kubectl get globalnetworkpolicies.crd.projectcalico.org
sudo systemctl status k3s chopin-network-guard
sudo nft list table inet chopin_guard
```

The `path:` flake reference includes new files during development without
requiring them to be staged in Git. No passwords or credentials are in this
repository. The declarative manifests are reconciled by K3s; make persistent
changes in the Nix/YAML files, then rebuild.

Try an application:

```sh
sudo k3s kubectl apply -f chopin/examples/application.yaml
sudo k3s kubectl rollout status -n applications deployment/web
sudo k3s kubectl exec -n applications deployment/web -- uname -r
sudo k3s kubectl port-forward -n applications service/web 8080:8080
```

The last command allows an administrator to inspect the app locally on
Chopin at `http://127.0.0.1:8080`. Administrative port-forward/exec access is
privileged access and is not governed by ordinary pod-to-pod firewall rules.
For a browser on your computer, separately forward the local port over SSH:
`ssh -L 8080:127.0.0.1:8080 rocheque@192.168.1.82`.

The RuntimeClass reserves 1 GiB and 100 millicores of additional capacity per
pod for conservative VM overhead accounting. With workload limits, Kata sizes
guest memory as the workload memory limit plus 256 MiB; without limits it uses
1 GiB. Set realistic resource requests and limits on every application.
`local-path` PVCs live on Chopin's disk and are available inside Kata guests.
They are tied to this node and are not replicated; the provisioner's size
request is not a disk quota.

## Add security-group rules

Create administrator-managed namespaces for security groups. Group membership
should come from namespace labels rather than labels that application users
can edit on their own pods. Grant application users only namespaced workload
permissions; keep namespaces, Calico policies, RuntimeClasses, admission
policies, infrastructure namespaces, and privileged administrative access
under administrator control. No tenant RoleBindings are installed by default.
Application service accounts have no policy-management permissions.

`examples/security-groups.yaml` illustrates the two sides of allowing a frontend
namespace to connect to a database namespace on TCP 5432. It is not installed
automatically. Allow policies need `order` smaller than `1000` so they run before
the final deny. Both source egress and destination ingress must permit a flow.
Return traffic is stateful; removing a rule blocks new connections, while
existing tracked connections can remain until they end or conntrack expires.
An ordinary Kubernetes NetworkPolicy cannot override the explicit final deny.

For a fixed standalone server, rules may use a narrow destination/source CIDR
and port. This controls the Kubernetes side immediately. To enforce both sides,
enroll the trusted Linux host with Calico/Felix and an administrator-created
HostEndpoint, using restricted control-plane credentials. Calico on a server
is administered by that server's root user; if the workload must not be able
to alter enforcement, put enforcement on its trusted hypervisor or gateway.
No other servers were enrolled during this deployment.

There is no Headscale/Tailscale component in this setup. Calico provides the
security-group policy. The single-node pod network does not need an overlay
encryption service. Before adding nodes or remote servers, configure routing,
explicit node-to-node permissions, and encryption where needed. Current host
rules intentionally do not permit arbitrary new peers, VXLAN, or control-plane
clients. Calico's VXLAN configuration is prepared for future node networking;
VXLAN itself does not encrypt traffic.

## Recovery and backups

Inspect problems with `sudo journalctl -u k3s` and
`sudo k3s kubectl describe pod -n <namespace> <pod>`. Calico logs are in `kube-system` and in
`/var/log/calico/cni/cni.log`. The immutable containerd template and Kata
configuration are generated from `kubernetes.nix`; do not edit generated files
under `/var/lib/rancher/k3s/agent/etc/containerd`.

NixOS rollback: `sudo nixos-rebuild switch --rollback`. Network policies and
other cluster objects live in the Kubernetes datastore and are not removed by
a NixOS rollback. If host-policy recovery is necessary, use the local console
to remove the HostEndpoint and temporarily disable its manifest before
restarting K3s; do not remove the workload guard as a routine workaround.

This is one machine, not a highly available cluster. Back up the SQLite
datastore under `/var/lib/rancher/k3s/server/db`, the server token, and persistent
application data. Keep backup credentials and encryption keys protected.
The simplest consistent maintenance backup stops K3s, copies the entire server
directory and `/var/lib/rancher/k3s/storage` into a root-only backup directory,
then restarts K3s. Application VMs can survive a K3s service stop, so also quiesce
applications or take storage snapshots for consistent application-data backups.
Store encrypted copies off the machine; no off-host backup destination was
provided or configured.

## Verification

Deployment checks on 2026-09-30 confirmed separate guest kernels and boot IDs,
default deny, explicit TCP allow, denial after revocation, DNS, node/LAN/Internet
isolation, rejection of isolation bypasses, local-path storage inside a VM,
and the firewall guard's rejection of packets without Calico's approval mark.
The Kubernetes API and kubelet were unreachable from the LAN, while a fresh SSH
connection succeeded. The test workloads and temporary allow policies were
removed afterward.

Run `sudo bash chopin/verify-isolation.sh` after changes to the runtime or network
stack. It creates temporary test VMs and policies, verifies real traffic, and
cleans up. It needs an otherwise unused namespace called `isolation-check`.

Upstream references: [K3s containerd configuration](https://docs.k3s.io/advanced),
[Calico CNI configuration](https://docs.tigera.io/calico/latest/reference/configure-cni-plugins),
[Calico host endpoints](https://docs.tigera.io/calico/latest/reference/host-endpoints/overview),
and [Kata installation](https://github.com/kata-containers/kata-containers/blob/4.2.0/docs/installation.md).
