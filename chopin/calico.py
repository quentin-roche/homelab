"""Adapt the checksum-pinned upstream manifest for K3s on NixOS."""
import sys
import yaml

documents = list(yaml.safe_load_all(open(sys.argv[1])))
for document in documents:
    if document.get("kind") == "ConfigMap" and document["metadata"]["name"] == "calico-config":
        document["data"]["calico_backend"] = "vxlan"
        document["data"]["cni_network_config"] = document["data"]["cni_network_config"].replace(
            '"type": "calico",',
            '"type": "calico",\n      "readiness_gates": ["http://localhost:9099/readiness"],\n      "policy_setup_timeout_seconds": 30,'
        )
    if document.get("kind") != "DaemonSet" or document["metadata"]["name"] != "calico-node":
        continue
    spec = document["spec"]["template"]["spec"]
    container = spec["containers"][0]
    values = {
        "CLUSTER_TYPE": "k8s",
        "CALICO_IPV4POOL_IPIP": "Never",
        "CALICO_IPV4POOL_VXLAN": "Always",
        "CALICO_IPV4POOL_CIDR": "10.42.0.0/16",
        "IP_AUTODETECTION_METHOD": "interface=enp1s0f1",
        "FELIX_DEFAULTENDPOINTTOHOSTACTION": "RETURN",
        "FELIX_IPTABLESBACKEND": "NFT",
        "FELIX_IPV6SUPPORT": "true",
        "FELIX_ENDPOINTSTATUSPATHPREFIX": "/var/run/calico",
    }
    for variable in container["env"]:
        if variable["name"] in values:
            variable.pop("valueFrom", None)
            variable["value"] = values.pop(variable["name"])
    container["env"].extend({"name": name, "value": value} for name, value in values.items())
    for probe in ["livenessProbe", "readinessProbe"]:
        container[probe]["exec"]["command"] = [
            argument for argument in container[probe]["exec"]["command"]
            if not argument.startswith("-bird-")
        ]
    for init in spec["initContainers"]:
        if init["name"] == "install-cni":
            init["env"].append({"name": "CNI_NET_DIR", "value": "/var/lib/rancher/k3s/agent/etc/cni/net.d"})
    paths = {
        "cni-bin-dir": "/var/lib/rancher/k3s/data/cni",
        "cni-net-dir": "/var/lib/rancher/k3s/agent/etc/cni/net.d",
        "lib-modules": "/run/current-system/kernel-modules/lib/modules",
    }
    for volume in spec["volumes"]:
        if volume["name"] in paths:
            volume["hostPath"]["path"] = paths[volume["name"]]
            if volume["name"] == "cni-net-dir":
                volume["hostPath"]["type"] = "DirectoryOrCreate"

yaml.safe_dump_all(documents, sys.stdout, sort_keys=False)
