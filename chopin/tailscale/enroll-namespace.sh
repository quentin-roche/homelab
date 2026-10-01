#!/usr/bin/env bash
# Administrator only. Never print enrollment credentials.
set -euo pipefail
namespace=${1:?usage: enroll-namespace.sh NAMESPACE TAG [EXPIRATION]}
tag=${2:?an administrator-owned tag is required}
expiration=${3:-24h}
[[ "$namespace" =~ ^[a-z0-9][a-z0-9-]*$ && "$tag" =~ ^tag:[a-z0-9][a-z0-9-]*$ ]] || exit 2
umask 077
enrollment_dir=$(mktemp -d)
trap 'rm -rf "$enrollment_dir"' EXIT
owner_id=$(headscale users list -o json | jq -er --arg owner "namespace-$namespace" '.[] | select(.name == $owner) | .id')
headscale preauthkeys create --user "$owner_id" --reusable --ephemeral \
  --expiration "$expiration" --tags "$tag" -o json | jq -er '.key' > "$enrollment_dir/authkey"
k3s kubectl create secret generic tailscale-enrollment -n "$namespace" \
  --from-file=authkey="$enrollment_dir/authkey" --dry-run=client -o yaml | k3s kubectl apply -f -
