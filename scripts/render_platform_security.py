"""Render the administrator-owned parts of the pinned platform charts."""
import argparse
import subprocess
import tempfile
import copy
from pathlib import Path

import yaml


def render_security(release_file, chart_path):
    release = next(obj for obj in yaml.safe_load_all(Path(release_file).read_text())
                   if obj and obj['kind'] == 'HelmRelease')
    spec = release['spec']
    values = spec['values']
    if release['metadata']['name'] == 'cert-manager':
        values['crds']['enabled'] = True
    with tempfile.TemporaryDirectory() as temp:
        value_path = Path(temp) / 'values.yaml'
        value_path.write_text(yaml.safe_dump(values))
        rendered = subprocess.check_output([
            'helm', 'template', spec['releaseName'], str(chart_path),
            '--namespace', spec['targetNamespace'], '--kube-version', '1.35.0',
            '--skip-tests', '--values', str(value_path)], text=True)
    kinds = {'ServiceAccount', 'Role', 'RoleBinding', 'ClusterRole',
             'ClusterRoleBinding', 'CustomResourceDefinition', 'IngressClass',
             'MutatingWebhookConfiguration', 'ValidatingWebhookConfiguration'}
    objects = []
    for obj in yaml.safe_load_all(rendered):
        if not obj or obj['kind'] not in kinds:
            continue
        metadata = obj['metadata']
        metadata.setdefault('labels', {})['homelab/owner'] = 'nix'
        # These resources are never Helm-owned, including on uninstall.
        (metadata.get('annotations') or {}).pop('helm.sh/resource-policy', None)
        if not metadata.get('annotations'):
            metadata.pop('annotations', None)
        objects.append(obj)
    if release['metadata']['name'] == 'traefik':
        # Only discovery belongs at cluster scope; TLS secrets stay in the two
        # namespaces actually watched by Traefik.
        role = next(obj for obj in objects if obj['kind'] == 'ClusterRole')
        cluster_resources = {'nodes', 'namespaces', 'ingressclasses'}
        local_rules = []
        cluster_rules = []
        for rule in role['rules']:
            for resources, target in [
                ([r for r in rule['resources'] if r in cluster_resources], cluster_rules),
                ([r for r in rule['resources'] if r not in cluster_resources], local_rules),
            ]:
                if resources:
                    target.append({**rule, 'resources': resources})
        role['rules'] = cluster_rules
        binding = next(obj for obj in objects if obj['kind'] == 'ClusterRoleBinding')
        for namespace in spec['values']['providers']['kubernetesIngress']['namespaces']:
            local = copy.deepcopy(role)
            local['kind'] = 'Role'
            local['metadata']['namespace'] = namespace
            local['rules'] = copy.deepcopy(local_rules)
            local_binding = copy.deepcopy(binding)
            local_binding['kind'] = 'RoleBinding'
            local_binding['metadata']['namespace'] = namespace
            local_binding['roleRef']['kind'] = 'Role'
            objects.extend([local, local_binding])
    return objects


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', required=True)
    parser.add_argument('--chart', required=True)
    args = parser.parse_args()
    print(yaml.safe_dump_all(render_security(args.release, args.chart), sort_keys=False))
