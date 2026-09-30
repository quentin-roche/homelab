#!/bin/sh
set -eu
# This firewall protects against ordinary application processes. Guest root can
# change it; the separate host transport guard remains the bypass boundary.
iptables -N guest-input 2>/dev/null || true
iptables -F guest-input
iptables -A guest-input -i lo -j ACCEPT
iptables -A guest-input -i tailscale0 -j ACCEPT
iptables -A guest-input -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A guest-input -p udp --dport 41641 -j ACCEPT
iptables -A guest-input -j DROP
iptables -C INPUT -j guest-input 2>/dev/null || iptables -I INPUT 1 -j guest-input
ip6tables -N guest-input 2>/dev/null || true
ip6tables -F guest-input
ip6tables -A guest-input -i lo -j ACCEPT
ip6tables -A guest-input -i tailscale0 -j ACCEPT
ip6tables -A guest-input -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A guest-input -j DROP
ip6tables -C INPUT -j guest-input 2>/dev/null || ip6tables -I INPUT 1 -j guest-input
mkdir -p /dev/net /var/run/tailscale /var/lib/tailscale
[ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200
chmod 600 /dev/net/tun
tailscaled --no-logs-no-support --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock --port=41641 &
daemon=$!
trap 'kill "$daemon"; wait "$daemon" || true' TERM INT EXIT
until tailscale --socket=/var/run/tailscale/tailscaled.sock status --json >/dev/null 2>&1; do
  kill -0 "$daemon"
  sleep 1
done
tailscale --socket=/var/run/tailscale/tailscaled.sock up \
  --login-server=http://192.168.1.82:8080 --auth-key=file:/enroll/authkey \
  --hostname="$POD_NAME" --accept-dns=false --accept-routes=false \
  --netfilter-mode=off
wait "$daemon"
