# Traefik

Flux installs chart 41.6.1 (Traefik 3.7.13) in `platform-services`.
The Nix platform module installs its service account, namespace-scoped workload
discovery permissions, cluster discovery permissions, `traefik` IngressClass,
and Calico access rules. Helm post-renderers remove those administrator-owned
objects from the release. Traefik cannot read Secrets in `kube-system` or
`flux-system`. Its pod runs in Kata with restricted security and resource limits.

Use standard `networking.k8s.io/v1` Ingress with
`spec.ingressClassName: traefik`. The CRD and Gateway providers are disabled.
The dashboard and metrics are not exposed. TLS certificates come from
cert-manager Secrets; Traefik's own ACME resolver is not configured.

HTTP is available at `http://192.168.1.167:30080` and HTTPS at
`https://192.168.1.167:30443` from the LAN. The management IP uses DHCP.
NodePorts preserve the client address; Calico denies non-LAN clients.
No LoadBalancer controller, public forwarding, or router change is required.
Unmatched requests return 404. HTTPS uses Traefik's generated certificate until
an Ingress references a TLS Secret.

Backend pod labels must include `homelab/ingress: "true"`; this permits inbound
TCP from Traefik in `applications` or `platform-services`. Other application
access remains denied. Set `tls.hosts` and `tls.secretName` on each HTTPS Ingress.
For automatic issuance also use `cert-manager.io/issuer` (namespaced Issuer)
or `cert-manager.io/cluster-issuer` (Nix-owned ClusterIssuer).

```sh
ssh chopin 'env KUBECONFIG=/etc/rancher/k3s/k3s.yaml flux get helmreleases'
ssh chopin 'k3s kubectl -n platform-services rollout status deployment/traefik'
curl -i http://192.168.1.167:30080/
```
