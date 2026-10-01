# Cluster runtime

NixOS starts K3s, Kata, Calico and Flux. Flux then manages applications and
additional services from Git. Keeping the runtime in Nix avoids a bootstrap
cycle: Flux itself needs both Calico networking and the Kata runtime to start.
Calico and Kata are not Helm-managed in this configuration.

There are three Nix files:

| File | Responsibility |
| --- | --- |
| `default.nix` | K3s, containerd/Kata configuration, networking and essential isolation |
| `flux.nix` | Flux installation, scoped access, Git entry point and external credential provisioning |
| `packages.nix` | Checksum-pinned dependencies, Kata packaging and the shared Kustomize builder |

The `calico/` and `flux/` folders contain YAML overlays. Host settings belong
under `chopin/`; application definitions belong under `kubernetes/`.

## Reuse on another host

This module creates an independent single-node K3s cluster on x86_64 Linux with
KVM. Import it and supply the host's network identity:

```nix
{
  imports = [ ../modules/kubernetes ];
  homelab.kubernetes = {
    enable = true;
    # nodeName defaults to networking.hostName.
    nodeIP = "192.168.1.83";
    interface = "enp1s0";
    lanCIDR = "192.168.1.0/24";
    dnsServerCIDRs = [ "192.168.1.254/32" ];
    # Defaults: podCIDR = "10.42.0.0/16"; serviceCIDR = "10.43.0.0/16";
  };
}
```

External flakes can import `homelab.nixosModules.kubernetes`. Configure disks,
static networking, SSH users and `kvm-amd` or `kvm-intel` in the host module.
[Chopin](../../chopin/README.md) shows the complete setup, including Flux.
Joining nodes into one cluster additionally requires credentials, routing and
node policies; changing existing pod/service CIDRs requires a migration.
Calico pool initialization values do not rewrite existing pools.

## Startup and ownership

1. NixOS configures the host and immutable Kata/containerd runtime, then starts
   the nftables guard before K3s.
2. K3s applies Nix-owned Calico and essential admission/network policies.
3. The Nix-installed Flux controllers start with Kata once networking is ready.
   Protected external files supply the age identity and optional Git credentials.
4. Flux reconciles the cluster entry point in Git, using Kustomize or Helm for
   selected applications and services.

K3s/Nixpkgs are locked in `flake.lock`; Calico 3.32.2, Kata 4.2.0 and Flux 2.9.5
are pinned in `packages.nix`. Calico and Flux are rendered with Kustomize.
Application updates need Git reconciliation, not a NixOS rebuild. Do not add
application resources to `services.k3s.manifests` or give Flux ownership of the
runtime. See [application management](../../kubernetes/README.md) for permissions,
secret provisioning and the single, initially empty cluster entry point.

## Isolation

Each application pod runs in its own Kata VM; containers within a pod share it.
Calico enforces policy on the host outside that VM. Flannel and K3s's policy
controller are disabled. Applications have final ingress/egress deny policies;
only DNS to CoreDNS is allowed by default. Internet, LAN, node, API and other
pod traffic require explicit administrator-managed allow policies.

Admission requires `runtimeClassName: kata-qemu` outside infrastructure
namespaces. It rejects host namespaces/paths/ports, privileged containers,
direct device allocation, extra networks, spoofing annotations and Kata
configuration overrides. Application namespaces enforce restricted Pod Security.
System pods in `kube-system` use the ordinary runtime for required host access.
Only trusted administrators should deploy there or manage cluster policies.

The nftables guard rejects new pod traffic without Calico's approval mark,
including during startup. Established/related connections remain stateful.
The host has a wildcard Calico HostEndpoint: SSH is permitted from `lanCIDR`,
while the API and kubelet are not exposed to LAN clients. Host egress permits
cluster traffic, configured DNS, image/update HTTP/HTTPS, NTP, DHCP and ICMP.
Applications do not inherit those permissions. Host policies cover IPv4/IPv6;
pod networking is IPv4 only. VXLAN is not encryption and additional peers need
explicit routing, permissions and encryption where appropriate.

The RuntimeClass reserves 1 GiB and 100 millicores of VM overhead per pod.
Guest memory uses workload limits plus 256 MiB, or 1 GiB without limits; set
realistic requests and limits. Local-path PVCs work inside Kata but are tied to
this node, are not replicated, and their size request is not a disk quota.
The trusted base includes the host, KVM, QEMU, virtiofsd, Kata and administrators;
keep the host and bundled runtime/guest patched.

For security-group access, use administrator-managed namespace labels and
policies; application accounts cannot manage them. The optional
`examples/security-groups.yaml` shows a frontend/database TCP 5432 allowance.
Both source egress and destination ingress must permit a connection. Use an
order below `1000` to precede the final deny. Ordinary Kubernetes NetworkPolicy
cannot override that deny. Revocation blocks new connections; tracked ones may
survive until they end or expire. For external servers, enforce the other side
on a trusted host, hypervisor or gateway with separately protected credentials.

## Operate and recover

Change runtime configuration in Git and rebuild NixOS after reviewing the
migration. Do not edit generated containerd files or apply `.yaml.in` templates
manually. Kubernetes objects persist across NixOS rollbacks, and K3s does not
automatically delete retired manifests. Use the local console for host-policy
recovery; do not disable the workload guard as a routine workaround.

```sh
sudo k3s kubectl get pods -A
sudo systemctl status k3s homelab-network-guard
sudo journalctl -u k3s
sudo nft list table inet homelab_guard
# Runtime/network changes also need the live isolation checks:
sudo bash modules/kubernetes/verify-isolation.sh 192.168.1.82 192.168.1.254
```

The isolation check creates temporary VMs and policies in the otherwise unused
`isolation-check` namespace, verifies traffic/admission and cleans up afterward.
Calico logs are in `kube-system` and `/var/log/calico/cni/cni.log`.

Git restores configuration. Back up the K3s datastore/server token, external
credentials and application data separately to protected off-machine storage.
Stopping K3s alone may leave application VMs running: quiesce them or use
consistent storage snapshots. Follow the [recovery runbook](../../kubernetes/RECOVERY.md)
and [host guide](../../chopin/README.md) for a held startup, reinstall and restoration.
No off-host backup destination is configured. No Headscale/Tailscale component
is declared here; inspect additional live services before a migration.
