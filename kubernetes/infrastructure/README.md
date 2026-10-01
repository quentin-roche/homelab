# Additional cluster services

Put reusable service Kustomizations here and select them in
`kubernetes/clusters/chopin/kustomization.yaml`. This directory starts empty.

K3s, Calico, Kata, Flux, namespaces, RBAC, and essential policies belong to Nix.
Additional services run under Kata in the Nix-created `platform-services`
namespace. Flux permissions cover namespaced workloads there, not cluster-level
resources. A service needing CRDs, namespaces, RBAC or policy changes requires an
explicit Nix configuration change.

For Helm, put the HelmRepository/HelmRelease in `flux-system`, pin the chart
version, and set `serviceAccountName: flux-reconciler` and both `targetNamespace`
and `storageNamespace` to `platform-services`. Disable namespace creation. Use
chart values or a post-renderer for Kata/restricted contexts and disabled token
mounts. Supply the pinned chart artifact to validation with `--helm-chart
<release-name>=<artifact-path>` before enabling the service.
