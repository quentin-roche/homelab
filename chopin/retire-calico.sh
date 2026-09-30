#!/usr/bin/env bash
# Idempotent upgrade from this repository's previous Calico deployment.
set -euo pipefail
k() { k3s kubectl "$@"; }
for attempt in $(seq 1 90); do
  k get nodes >/dev/null 2>&1 && break
  sleep 2
done
migration_dir=/var/lib/chopin/calico-migration
install -d -m 700 "$migration_dir"
manifest_dir=/var/lib/rancher/k3s/server/manifests
cni_dir=/var/lib/rancher/k3s/agent/etc/cni/net.d
# K3s retains obsolete AddOn sources; remove only the known retired sources.
for name in 00-calico.yaml 20-host-security.yaml; do
  if [ -e "$manifest_dir/$name" ]; then
    cp -L "$manifest_dir/$name" "$migration_dir/$name"
    rm "$manifest_dir/$name"
  fi
done
if k -n kube-system get daemonset calico-node >/dev/null 2>&1; then
  if k get crd hostendpoints.crd.projectcalico.org >/dev/null 2>&1; then
    k delete hostendpoint.crd.projectcalico.org chopin --ignore-not-found
  fi
  # Switch new infrastructure sandboxes before retiring the old CNI agents.
  test -f "$cni_dir/10-flannel.conflist"
  cp "$cni_dir/10-flannel.conflist" "$cni_dir/00-flannel.conflist"
  for deployment in coredns local-path-provisioner metrics-server calico-kube-controllers; do
    if k -n kube-system get deployment "$deployment" >/dev/null 2>&1; then
      k -n kube-system rollout restart deployment "$deployment"
      k -n kube-system rollout status deployment "$deployment" --timeout=120s
    fi
  done
  k -n kube-system delete daemonset calico-node --wait=true
  k -n kube-system delete deployment calico-kube-controllers --ignore-not-found
fi
if k get crd globalnetworkpolicies.crd.projectcalico.org >/dev/null 2>&1; then
  k delete globalnetworkpolicy.crd.projectcalico.org chopin-host-services application-default-deny --ignore-not-found
fi
# Preserve credentials for rollback; do not retain them in the active CNI dir.
for name in 10-calico.conflist calico-kubeconfig; do
  if [ -f "$cni_dir/$name" ]; then mv "$cni_dir/$name" "$migration_dir/$name"; fi
done
rm -f "$cni_dir/00-flannel.conflist"
# Remove only Calico rules/references; preserve NixOS, K3s and Tailscale rules.
for family in iptables ip6tables; do
  "${family}-save" | sed '/cali[-:]/d' > "$migration_dir/$family-without-calico"
  "${family}-restore" --test < "$migration_dir/$family-without-calico"
  "${family}-restore" < "$migration_dir/$family-without-calico"
done
if nft list table inet chopin_guard >/dev/null 2>&1; then nft delete table inet chopin_guard; fi
if ip link show vxlan.calico >/dev/null 2>&1; then ip link delete vxlan.calico; fi
