# cert-manager

Flux installs chart v1.21.2 in `platform-services`. Controller, webhook and
cainjector run under Kata with restricted security and explicit limits.
Nix installs the six CRDs, service accounts, RBAC and webhook registrations
from the checksum-pinned chart. Helm post-renderers exclude those objects,
and Helm skips CRD installation/upgrades. Update the chart pin and checksum
in `packages.nix` together with `release.yaml`, rebuild NixOS prerequisites,
then reconcile Flux. Uninstalling the workload release retains the CRDs.

Let's Encrypt is the selected provider, but no production Issuer is configured
until a domain and DNS provider are available.
For Let's Encrypt, DNS-01 suits this LAN-only cluster: the controller may reach
public HTTPS and DNS, but private/LAN destinations are excluded. DNS API tokens
belong in SOPS-encrypted application Secrets. Set the public age recipient in
`.sops.yaml` and provision its private identity outside the checkout before
adding encrypted Secrets. Back up the identity off-machine.

Flux may manage Issuers and Certificates in `applications` and
`platform-services`. ClusterIssuers remain administrator/Nix-owned; their
credential Secrets live in `platform-services` (the configured cluster resource
namespace). Ingress annotations request a Secret in the Ingress namespace;
Traefik consumes that Secret.

HTTP-01 needs further configuration: its dynamically created solver pods must
satisfy Kata admission, and public challenge traffic must be explicitly allowed.
The default solver pod is intentionally not exempt from isolation. DNS-01 avoids
that requirement. Public router forwarding and wildcard DNS are not configured.

```sh
ssh chopin 'k3s kubectl -n platform-services get deployments'
ssh chopin 'k3s kubectl get certificates,issuers -A'
ssh chopin 'k3s kubectl get clusterissuers'
```
