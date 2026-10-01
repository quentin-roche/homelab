# Applications

Put reusable application Kustomizations here. Add selected applications to
`kubernetes/clusters/chopin/kustomization.yaml`. No demonstration app is installed.

Workloads belong in the Nix-created `applications` namespace. Each Pod must use
`runtimeClassName: kata-qemu`, restricted security settings, no automatic API
token, and explicit resource limits. Network access beyond CoreDNS needs a
Nix-owned Calico allow rule. Store application Secrets only as SOPS-encrypted
`*.sops.yaml` files; see [the cluster guide](../README.md).
