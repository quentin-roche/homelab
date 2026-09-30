#!/usr/bin/env bash
# Optional smoke checks; no policy changes or additional workloads.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root on Chopin' >&2; exit 1; }
k() { k3s kubectl "$@"; }
k wait -n applications --for=condition=Ready pods -l app=web --timeout=180s
pod=$(k -n applications get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
address=$(k -n applications exec "$pod" -c tailscale -- tailscale ip -4)
curl --connect-timeout 15 --max-time 20 -fsS "http://$address:8080"
# The demo listens on 8080. A timeout through its ordinary address proves the
# path is blocked, rather than merely finding an unused port.
underlay=$(k -n applications get pod "$pod" -o jsonpath='{.status.podIP}')
if curl --connect-timeout 3 --max-time 4 -fsS "http://$underlay:8080"; then
  echo 'FAIL: ordinary pod address bypassed the guest firewall' >&2; exit 1
fi
k -n applications exec "$pod" -c web -- nslookup kubernetes.default.svc.cluster.local
host_boot=$(cat /proc/sys/kernel/random/boot_id)
guest_boot=$(k -n applications exec "$pod" -c web -- cat /proc/sys/kernel/random/boot_id)
[[ $host_boot != "$guest_boot" ]]
k -n applications exec "$pod" -c web -- sh -c 'wget -T 2 -qO- http://192.168.1.82:6443' && exit 1
nft list table inet chopin_kata_guard
nft list table bridge chopin_kata_guard
headscale nodes list
printf '%s\n' 'PASS: allowed overlay HTTP, blocked ordinary pod path/API, DNS and separate guest kernel.'
