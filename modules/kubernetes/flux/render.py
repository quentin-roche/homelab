"""Adapt the checksum-pinned Flux distribution; do not read any credentials."""
import argparse
import ipaddress
import sys
import yaml

parser = argparse.ArgumentParser()
parser.add_argument("manifest")
parser.add_argument("node_ip")
parser.add_argument("service_cidr")
parser.add_argument("pod_cidr")
parser.add_argument("lan_cidr")
args = parser.parse_args()
if ipaddress.ip_address(args.node_ip).version != 4 or any(
    ipaddress.ip_network(cidr).version != 4 for cidr in [args.service_cidr, args.pod_cidr, args.lan_cidr]
):
    parser.error("The cluster node and networks must be IPv4")
controllers = {"source-controller", "kustomize-controller", "helm-controller"}
with open(args.manifest) as stream:
    upstream = list(yaml.safe_load_all(stream))
result = []
for obj in upstream:
    obj.pop("status", None)
    obj.get("metadata", {}).pop("creationTimestamp", None)
    kind, name = obj["kind"], obj["metadata"]["name"]
    if kind == "CustomResourceDefinition":
        if obj["spec"]["group"] not in {
            "source.toolkit.fluxcd.io", "kustomize.toolkit.fluxcd.io", "helm.toolkit.fluxcd.io"
        }:
            continue
    elif kind == "Namespace":
        obj["metadata"].setdefault("labels", {}).update({
            "pod-security.kubernetes.io/enforce": "restricted",
            "pod-security.kubernetes.io/enforce-version": "v1.35",
            "pod-security.kubernetes.io/audit": "restricted",
            "pod-security.kubernetes.io/warn": "restricted",
        })
    elif kind == "ServiceAccount":
        if name not in controllers:
            continue
    elif kind == "Service":
        if name != "source-controller":
            continue
    elif kind == "Deployment":
        if name not in controllers:
            continue
        pod = obj["spec"]["template"]["spec"]
        pod["runtimeClassName"] = "kata-qemu"
        pod["automountServiceAccountToken"] = True
        pod.pop("priorityClassName", None)
        pod["securityContext"].update({"runAsUser": 65534, "runAsNonRoot": True,
            "seccompProfile": {"type": "RuntimeDefault"}})
        container = pod["containers"][0]
        container["args"] = [a for a in container["args"]
            if not a.startswith("--events-addr=") and a != "--watch-all-namespaces"]
        container["args"].append("--watch-all-namespaces=false")
        if name in {"kustomize-controller", "helm-controller"}:
            container["args"] += ["--no-cross-namespace-refs=true", "--default-service-account=default"]
        if name == "kustomize-controller":
            container["args"].append("--no-remote-bases=true")
    else:
        # Replace upstream RBAC and permissive NetworkPolicies with our explicit
        # namespace-scoped RBAC and Calico rules. No cluster-admin binding.
        continue
    obj["metadata"].setdefault("labels", {})["homelab/owner"] = "nix"
    result.append(obj)

api_ip = str(ipaddress.ip_network(args.service_cidr)[1])
private = ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4"]
selected = "projectcalico.org/namespace == 'flux-system' && app in {'source-controller', 'kustomize-controller', 'helm-controller'}"
result.append({"apiVersion": "crd.projectcalico.org/v1", "kind": "GlobalNetworkPolicy",
    "metadata": {"name": "flux-runtime-access", "labels": {"homelab/owner": "nix"}},
    "spec": {"order": 80, "selector": selected, "types": ["Ingress", "Egress"],
        "ingress": [
            {"action": "Allow", "protocol": "TCP", "source": {"selector": selected},
             "destination": {"selector": "app == 'source-controller'", "ports": [9090]}},
            {"action": "Allow", "protocol": "TCP", "source": {"nets": [args.node_ip + "/32"]},
             "destination": {"ports": [9440, 9090]}}],
        "egress": [
            {"action": "Allow", "protocol": "TCP", "destination": {
                "nets": [args.node_ip + "/32"], "ports": [6443]}},
            {"action": "Allow", "protocol": "TCP", "destination": {
                "nets": [api_ip + "/32"], "ports": [443]}},
            {"action": "Allow", "protocol": "TCP", "destination": {
                "selector": "projectcalico.org/namespace == 'flux-system' && app == 'source-controller'", "ports": [9090]}},
            {"action": "Allow", "protocol": "TCP", "source": {"selector": "app == 'source-controller'"},
             "destination": {"nets": ["0.0.0.0/0"], "notNets": private + [args.node_ip + "/32", args.service_cidr, args.pod_cidr, args.lan_cidr], "ports": [443]}}
        ]}})
yaml.safe_dump_all(result, sys.stdout, sort_keys=False)
