#!/usr/bin/env bash
# Integration check on Chopin; run as root. No permanent workloads are installed.
set -euo pipefail
if [[ ${EUID} != 0 ]]; then
  echo "Run with sudo bash chopin/verify-isolation.sh" >&2
  exit 1
fi
k() { k3s kubectl "$@"; }
task_ns=isolation-check
if k get namespace "$task_ns" >/dev/null 2>&1; then
  echo "Namespace $task_ns already exists; refusing to modify it." >&2
  exit 1
fi
task_policies=$(k get globalnetworkpolicies.crd.projectcalico.org -o json)
if jq -e '.items | any(.metadata.name == "isolation-check-egress" or .metadata.name == "isolation-check-ingress")' <<< "$task_policies" >/dev/null; then
  echo "Test policy names already exist; refusing to modify them." >&2
  exit 1
fi
# Install cleanup only after successfully creating a namespace we own.
k create namespace "$task_ns"
task_tmp=$(mktemp -d)
cleanup() {
  k delete globalnetworkpolicy.crd.projectcalico.org isolation-check-egress isolation-check-ingress --ignore-not-found >/dev/null || true
  k delete namespace "$task_ns" --ignore-not-found --wait=false >/dev/null || true
  rm -rf "$task_tmp"
}
trap cleanup EXIT
cat > "$task_tmp/pod.json" <<'JSON'
{
  "apiVersion": "v1", "kind": "Pod",
  "metadata": {"name": "client", "namespace": "isolation-check", "labels": {"app": "client"}},
  "spec": {
    "runtimeClassName": "kata-qemu", "automountServiceAccountToken": false,
    "securityContext": {"runAsUser": 1000, "runAsNonRoot": true, "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": "busybox", "image": "docker.io/library/busybox:1.37.0",
      "command": ["sh", "-c", "sleep 3600"],
      "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}},
      "resources": {"requests": {"cpu": "100m", "memory": "64Mi"}, "limits": {"cpu": "1", "memory": "128Mi"}}
    }]
  }
}
JSON
k apply -f "$task_tmp/pod.json"
jq '.metadata.name="server" | .metadata.labels.app="server" | .spec.containers[0].command=["sh","-c","mkdir -p /tmp/www; echo kata-calico-ok > /tmp/www/index.html; httpd -f -p 8080 -h /tmp/www"]' "$task_tmp/pod.json" > "$task_tmp/server.json"
k apply -f "$task_tmp/server.json"
k wait -n "$task_ns" --for=condition=Ready pod/client pod/server --timeout=120s
task_server_ip=$(k get pod -n "$task_ns" server -o jsonpath='{.status.podIP}')
task_client_boot=$(k exec -n "$task_ns" client -- cat /proc/sys/kernel/random/boot_id)
task_server_boot=$(k exec -n "$task_ns" server -- cat /proc/sys/kernel/random/boot_id)
[[ "$task_client_boot" != "$task_server_boot" && "$task_client_boot" != "$(cat /proc/sys/kernel/random/boot_id)" ]]
echo "PASS: different guest and host boot IDs"
k exec -n "$task_ns" client -- nslookup kubernetes.default.svc.cluster.local

blocked() {
  local task_url=$1 task_output
  if task_output=$(k exec -n "$task_ns" client -- wget -T 2 -qO- "$task_url" 2>&1); then
    echo "FAIL: reachable $task_url" >&2
    exit 1
  fi
  # A refused port or HTTP error alone would not prove policy enforcement.
  if ! grep -q 'timed out' <<< "$task_output"; then
    echo "FAIL: unexpected failure for $task_url: $task_output" >&2
    exit 1
  fi
  echo "PASS: blocked $task_url"
}
blocked "http://$task_server_ip:8080"
blocked "http://192.168.1.82:22"
blocked "http://192.168.1.82:6443"
blocked "http://192.168.1.254:80"
blocked "http://1.1.1.1:80"

cat > "$task_tmp/allow.yaml" <<'YAML'
apiVersion: crd.projectcalico.org/v1
kind: GlobalNetworkPolicy
metadata:
  name: isolation-check-egress
spec:
  order: 100
  selector: "projectcalico.org/namespace == 'isolation-check' && app == 'client'"
  types: [Egress]
  egress:
    - action: Allow
      protocol: TCP
      destination:
        selector: "projectcalico.org/namespace == 'isolation-check' && app == 'server'"
        ports: [8080]
---
apiVersion: crd.projectcalico.org/v1
kind: GlobalNetworkPolicy
metadata:
  name: isolation-check-ingress
spec:
  order: 100
  selector: "projectcalico.org/namespace == 'isolation-check' && app == 'server'"
  types: [Ingress]
  ingress:
    - action: Allow
      protocol: TCP
      source:
        selector: "projectcalico.org/namespace == 'isolation-check' && app == 'client'"
      destination:
        ports: [8080]
YAML
k apply -f "$task_tmp/allow.yaml"
task_allowed=false
for task_attempt in {1..10}; do
  if [[ $(k exec -n "$task_ns" client -- wget -T 2 -qO- "http://$task_server_ip:8080" 2>/dev/null) == kata-calico-ok ]]; then
    task_allowed=true
    break
  fi
  sleep 1
done
[[ "$task_allowed" == true ]]
echo "PASS: explicit allow works"
k delete -f "$task_tmp/allow.yaml"
# Reconciliation is asynchronous. Wait before checking a new connection.
sleep 3
blocked "http://$task_server_ip:8080"

rejected() {
  local task_name=$1 task_mutation=$2 task_output
  jq --arg name "rejected-$task_name" ".metadata.name=\$name | $task_mutation" "$task_tmp/pod.json" > "$task_tmp/rejected.json"
  if task_output=$(k create --dry-run=server -f "$task_tmp/rejected.json" 2>&1); then
    echo "FAIL: admission accepted $task_name" >&2
    exit 1
  fi
  if ! grep -q "ValidatingAdmissionPolicy 'require-kata-isolation'" <<< "$task_output"; then
    echo "FAIL: unexpected admission failure for $task_name: $task_output" >&2
    exit 1
  fi
  echo "PASS: admission rejected $task_name"
}
rejected runc 'del(.spec.runtimeClassName)'
rejected host-network '.spec.hostNetwork=true'
rejected host-pid '.spec.hostPID=true'
rejected host-ipc '.spec.hostIPC=true'
rejected host-path '.spec.volumes=[{"name":"host","hostPath":{"path":"/"}}]'
rejected host-port '.spec.containers[0].ports=[{"containerPort":8080,"hostPort":8080}]'
rejected privileged '.spec.containers[0].securityContext.privileged=true | .spec.containers[0].securityContext.allowPrivilegeEscalation=true'
rejected hypervisor '.metadata.annotations={"io.katacontainers.config.hypervisor.path":"/bin/sh"}'
rejected extra-network '.metadata.annotations={"k8s.v1.cni.cncf.io/networks":"other"}'
rejected spoof '.metadata.annotations={"cni.projectcalico.org/ipAddrsNoIpam":"[\"192.168.1.42\"]"}'
rejected device '.spec.containers[0].resources.limits["example.com/device"]="1"'
echo "PASS: isolation integration checks completed"
