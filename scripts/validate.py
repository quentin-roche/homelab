"""Offline checks for ownership, Flux dependencies, RBAC, schemas and isolation."""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

import jsonschema
import yaml


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load(text):
    return [obj for obj in yaml.safe_load_all(text) if obj]


def run(*args):
    return subprocess.check_output(args, text=True)


def key(obj):
    group = obj['apiVersion'].split('/')[0] if '/' in obj['apiVersion'] else ''
    meta = obj['metadata']
    return group, obj['kind'], meta.get('namespace', ''), meta['name']


def pod_spec(obj):
    kind = obj['kind']
    if kind == 'Pod':
        return obj['spec']
    if kind == 'CronJob':
        return obj['spec']['jobTemplate']['spec']['template']['spec']
    if kind in {'Deployment', 'StatefulSet', 'DaemonSet', 'ReplicaSet', 'Job'}:
        return obj['spec']['template']['spec']
    return None


def isolated(obj):
    pod = pod_spec(obj)
    if not pod:
        return
    require(pod.get('runtimeClassName') == 'kata-qemu', f'{key(obj)} missing Kata runtime')
    require(not any(pod.get(x) for x in ['hostNetwork', 'hostPID', 'hostIPC']), 'Host namespace bypass')
    require(not any('hostPath' in v for v in pod.get('volumes', [])), 'Host path bypass')
    psc = pod.get('securityContext', {})
    for c in pod['containers'] + pod.get('initContainers', []) + pod.get('ephemeralContainers', []):
        sc = c.get('securityContext', {})
        require(sc.get('allowPrivilegeEscalation') is False and not sc.get('privileged'), 'Privileged container')
        require('ALL' in sc.get('capabilities', {}).get('drop', []), 'Capabilities must be dropped')
        require(sc.get('runAsNonRoot', psc.get('runAsNonRoot')) is True, 'Non-root context missing')
        require(sc.get('seccompProfile', psc.get('seccompProfile', {})).get('type') == 'RuntimeDefault', 'Seccomp missing')
        require(not any(p.get('hostPort', 0) for p in c.get('ports', [])), 'Host port bypass')
        require(not any('/' in k for k in c.get('resources', {}).get('limits', {})), 'Direct device allocation')
        require(c.get('resources', {}).get('limits', {}).get('memory'), 'Guest memory limit missing')
        require(':latest' not in c['image'] and (':' in c['image'] or '@sha256:' in c['image']), 'Unpinned image')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--flux-manifest', type=Path, required=True)
    parser.add_argument('--kubernetes-schema', type=Path, required=True)
    parser.add_argument('--chart', type=Path, required=True)
    parser.add_argument('--calico-manifest', type=Path, required=True)
    parser.add_argument('--runtime-inputs', type=Path, required=True)
    args = parser.parse_args()
    repo = args.repo.resolve()
    require(hashlib.sha256(args.flux_manifest.read_bytes()).hexdigest() ==
        'cc3dcd743af16215838b6937e1fce83745bf24c0dcc6c59737c59df15429caaf', 'Flux distribution checksum changed')
    require(hashlib.sha256(args.chart.read_bytes()).hexdigest() ==
        '5ca7896889b539e04cdad4df2093ff1ff7576295e7e3ef90a1e1845e3a334d75', 'Helm chart checksum changed')
    require(hashlib.sha256(args.kubernetes_schema.read_bytes()).hexdigest() ==
        '483500149ee52ce5753d75f5639101d985bb4f5e902cc05b1ba7627465d62446', 'Kubernetes schema checksum changed')

    inputs = json.loads(args.runtime_inputs.read_text())
    require(inputs['assertions'] and not inputs['mutableUsers'], 'NixOS assertions/account settings failed')
    require(inputs['ssh']['AuthenticationMethods'] == 'publickey' and
        not inputs['ssh']['PasswordAuthentication'] and not inputs['ssh']['KbdInteractiveAuthentication'] and
        inputs['ssh']['PermitRootLogin'] == 'no', 'SSH authentication settings failed')
    require(hashlib.sha256(args.calico_manifest.read_bytes()).hexdigest() ==
        'a8c828a06a87c629a282ebbc424895b77f3a030251993e41ea400a743675bb02', 'Calico checksum changed')
    swagger = json.loads(args.kubernetes_schema.read_text())
    def normalize(value):
        if isinstance(value, dict):
            if value.get('format') == 'int-or-string' or value.get('x-kubernetes-int-or-string') is True:
                value['type'] = ['integer', 'string']
                value.pop('format', None)
            for child in value.values(): normalize(child)
        elif isinstance(value, list):
            for child in value: normalize(child)
    normalize(swagger)
    schemas = {}
    for definition in swagger['definitions'].values():
        for gvk in definition.get('x-kubernetes-group-version-kind', []):
            api = f"{gvk['group']}/{gvk['version']}" if gvk['group'] else gvk['version']
            schemas[(api, gvk['kind'])] = definition
    for obj in load(args.flux_manifest.read_text()) + load(args.calico_manifest.read_text()):
        if obj['kind'] == 'CustomResourceDefinition':
            spec = obj['spec']
            for v in spec['versions']:
                if v['served']:
                    schemas[(spec['group'] + '/' + v['name'], spec['names']['kind'])] = v['schema']['openAPIV3Schema']

    # Build the Nix-owned Flux runtime and test an independent second host.
    runtime = load(run(sys.executable, str(repo / 'modules/kubernetes/flux/render.py'),
        str(args.flux_manifest), inputs['nodeIP'], inputs['serviceCIDR'], inputs['podCIDR'], inputs['lanCIDR']))
    other = load(run(sys.executable, str(repo / 'modules/kubernetes/flux/render.py'),
        str(args.flux_manifest), '172.16.8.20', '10.53.0.0/16', '10.52.0.0/16', '172.16.8.0/24'))
    other_policy = next(x for x in other if x['kind'] == 'GlobalNetworkPolicy')
    require('192.168.1.82' not in json.dumps(other_policy) and '10.43.' not in json.dumps(other_policy), 'Shared Flux policy hardcodes Chopin')
    deployments = [x for x in runtime if x['kind'] == 'Deployment']
    require({x['metadata']['name'] for x in deployments} ==
        {'source-controller', 'kustomize-controller', 'helm-controller'}, 'Unexpected controller set')
    for obj in deployments:
        isolated(obj)
        flags = obj['spec']['template']['spec']['containers'][0]['args']
        require('--watch-all-namespaces=false' in flags, 'Controller must watch only flux-system')
        if obj['metadata']['name'] != 'source-controller':
            require('--default-service-account=default' in flags and '--no-cross-namespace-refs=true' in flags, 'Impersonation lockdown missing')
    policy = next(x for x in runtime if x['kind'] == 'GlobalNetworkPolicy')['spec']
    require(policy['order'] < 1000, 'Flux access must precede final deny')
    https = [r for r in policy['egress'] if r['destination'].get('nets') == ['0.0.0.0/0']]
    require(len(https) == 1 and https[0]['source']['selector'] == "app == 'source-controller'" and
        https[0]['destination']['ports'] == [443] and '192.168.0.0/16' in https[0]['destination']['notNets'], 'Excessive Flux Internet/LAN egress')

    calico = load(run(sys.executable, str(repo / 'modules/kubernetes/calico.py'),
        str(args.calico_manifest), inputs['interface'], inputs['podCIDR']))
    cm = next(o for o in calico if o['kind'] == 'ConfigMap' and o['metadata']['name'] == 'calico-config')
    cni = json.loads(cm['data']['cni_network_config'].replace('__CNI_MTU__', '0'))
    require(next(p for p in cni['plugins'] if p['type'] == 'calico')['policy_setup_timeout_seconds'] == 30, 'CNI fails open during policy setup')
    rbac = load((repo / 'modules/kubernetes/flux/rbac.yaml').read_text())
    for obj in rbac:
        if obj['kind'] == 'ClusterRole':
            require(obj['rules'] == [{'nonResourceURLs': ['/livez/ping'], 'verbs': ['head']}], 'Unexpected cluster-wide Flux permissions')
        if obj['kind'] == 'ClusterRoleBinding':
            require(obj['roleRef']['name'] == 'flux-api-health', 'Unexpected cluster-wide role binding')
    roles = {(x['metadata']['namespace'], x['metadata']['name']): x['rules'] for x in rbac if x['kind'] == 'Role'}
    bindings = [x for x in rbac if x['kind'] == 'RoleBinding']
    for obj in bindings:
        require((obj['metadata']['namespace'], obj['roleRef']['name']) in roles, 'Unresolved RoleBinding')
    def allowed(sa, obj, verb):
        group, kind, ns, _ = key(obj)
        # Plural names for types managed by this baseline.
        plurals = {'Kustomization': 'kustomizations', 'HelmRepository': 'helmrepositories',
            'HelmRelease': 'helmreleases', 'Ingress': 'ingresses', 'PersistentVolumeClaim': 'persistentvolumeclaims',
            'PodDisruptionBudget': 'poddisruptionbudgets', 'HorizontalPodAutoscaler': 'horizontalpodautoscalers'}
        resource = plurals.get(kind, kind.lower() + 's')
        for b in bindings:
            if b['metadata']['namespace'] != ns or not any(s['name'] == sa and s['namespace'] == 'flux-system' for s in b['subjects']):
                continue
            for r in roles[(ns, b['roleRef']['name'])]:
                if group in r['apiGroups'] and resource in r['resources'] and verb in r['verbs']:
                    return True
        return False
    for sa in ['flux-apps', 'flux-infrastructure', 'flux-orchestrator']:
        require(not allowed(sa, {'apiVersion': 'node.k8s.io/v1', 'kind': 'RuntimeClass', 'metadata': {'name': 'kata-qemu'}}, 'patch'), 'Flux can modify Kata')
    require(not allowed('flux-apps', {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'metadata': {'name': 'x', 'namespace': 'platform-services'}}, 'create'), 'App reconciler crosses boundary')

    owned = {}
    resources = []
    def own(obj, owner):
        k = key(obj)
        require(k not in owned, f'Duplicate resource ownership: {k} ({owned.get(k)} and {owner})')
        owned[k] = owner
        resources.append(obj)
    for obj in calico + runtime + rbac + load(inputs['hostSecurity']) + load((repo / 'modules/kubernetes/workload-security.yaml').read_text()):
        own(obj, 'Nix')
    seed = json.loads(inputs['fluxSync'])['items']
    for obj in seed:
        own(obj, 'Nix bootstrap')
    root = next(obj for obj in seed if obj['kind'] == 'Kustomization')
    require(root['spec']['serviceAccountName'] == 'flux-orchestrator', 'Invalid root impersonation')
    source = next(obj for obj in seed if obj['kind'] == 'GitRepository')
    require(source['metadata']['name'] == root['spec']['sourceRef']['name'] == 'homelab', 'Root source mismatch')
    for api, kind, name in [('v1', 'Secret', 'sops-age'), ('v1', 'Secret', 'flux-git-auth')]:
        owned[key({'apiVersion': api, 'kind': kind, 'metadata': {'name': name, 'namespace': 'flux-system'}})] = 'Nix bootstrap'

    entry = repo / root['spec']['path']
    children = load(run('kustomize', 'build', str(entry)))
    require(all(x['kind'] == 'Kustomization' and x['apiVersion'] == 'kustomize.toolkit.fluxcd.io/v1' for x in children), 'Cluster root must contain only child reconciliation objects')
    names = {x['metadata']['name'] for x in children}
    deps = {x['metadata']['name']: [d['name'] for d in x['spec'].get('dependsOn', [])] for x in children}
    def visit(name, trail):
        require(name not in trail, 'Flux dependency cycle')
        require(name in names, 'Unresolved Flux dependency')
        for dep in deps[name]: visit(dep, trail + [name])
    for name in names: visit(name, [])
    require('infrastructure' in deps['apps'], 'Apps must wait for infrastructure')
    for obj in children:
        own(obj, 'Flux cluster')
        require(allowed('flux-orchestrator', obj, 'create'), 'Root lacks child reconciliation permissions')
        spec = obj['spec']
        require(spec['decryption'] == {'provider': 'sops', 'secretRef': {'name': 'sops-age'}}, 'SOPS configuration missing')
        require(spec['sourceRef'] == {'kind': 'GitRepository', 'name': 'homelab'}, 'Unresolved source')
        path = (repo / spec['path']).resolve()
        require(path.is_relative_to(repo / 'kubernetes') and (path / 'kustomization.yaml').is_file(), 'Missing/escaping reconciliation path')
        built = load(run('kustomize', 'build', str(path)))
        for child in built:
            require(allowed(spec['serviceAccountName'], child, 'create') and allowed(spec['serviceAccountName'], child, 'patch'), f'RBAC denies {key(child)}')
            own(child, f"Flux {obj['metadata']['name']}")
            isolated(child)
            if child['kind'] != 'HelmRelease': continue
            hs = child['spec']
            require(hs['chart']['spec']['version'] == '6.15.0', 'Unpinned chart')
            require(hs['targetNamespace'] == hs['storageNamespace'] == 'platform-services', 'Helm storage/target scope mismatch')
            require(not hs['test']['enable'] and not hs['install']['createNamespace'], 'Unexpected hooks/namespace ownership')
            with tempfile.TemporaryDirectory() as temp:
                td = Path(temp)
                (td / 'values.yaml').write_text(yaml.safe_dump(hs['values']))
                rendered = run('helm', 'template', child['metadata']['name'], str(args.chart),
                    '--namespace', hs['targetNamespace'], '--kube-version', '1.35.0', '--skip-tests',
                    '--values', str(td / 'values.yaml'))
                (td / 'helm.yaml').write_text(rendered)
                patches = [p for renderer in hs['postRenderers'] for p in renderer['kustomize']['patches']]
                (td / 'kustomization.yaml').write_text(yaml.safe_dump({'apiVersion': 'kustomize.config.k8s.io/v1beta1',
                    'kind': 'Kustomization', 'resources': ['helm.yaml'], 'patches': patches}))
                for workload in load(run('kustomize', 'build', str(td))):
                    require(allowed(hs['serviceAccountName'], workload, 'create'), f'Helm RBAC denies {key(workload)}')
                    own(workload, 'Flux Helm')
                    isolated(workload)

    encrypted = []
    for path in repo.rglob('*'):
        if not path.is_file() or '.git' in path.parts or path.name == '.git': continue
        if path.suffix not in {'.yaml', '.yml', '.nix', '.py', '.sh', '.json', '.pub'}: continue
        content = path.read_text()
        require(not re.search(r'-----BEGIN (?:OPENSSH|RSA|EC|DSA|ENCRYPTED)? ?PRIVATE KEY-----|AGE-SECRET-KEY-1[A-Z0-9]{20,}', content), f'Private key detected in {path}')
        if 'kubernetes' not in path.relative_to(repo).parts or path.suffix != '.yaml': continue
        docs = load(content)
        if path.name.endswith('.sops.yaml'):
            require(docs and all('sops' in obj for obj in docs), f'Empty or unencrypted SOPS file: {path}')
        for obj in docs:
            if obj.get('kind') != 'Secret': continue
            require(path.name.endswith('.sops.yaml') and 'sops' in obj, f'Plaintext Secret in {path}')
            require(all(isinstance(v, str) and v.startswith('ENC[') for f in ['data', 'stringData'] for v in obj.get(f, {}).values()), f'Unencrypted Secret value in {path}')
            encrypted.append(path)
    creation = yaml.safe_load((repo / '.sops.yaml').read_text())['creation_rules'][0]
    recipient = creation.get('age', '')
    if encrypted:
        require(recipient.startswith('age1'), 'Configure the public age recipient before committing secrets')
    if not recipient:
        print('UNCONFIGURED: supply the public age recipient in .sops.yaml and provision/back up its external private identity.')
    for obj in resources:
        schema = schemas.get((obj['apiVersion'], obj['kind']))
        if schema:
            try:
                jsonschema.Draft7Validator({**schema, 'definitions': swagger['definitions']}).validate(obj)
            except Exception as exc:
                raise ValueError(f'Schema validation for {key(obj)}: {exc}') from exc
        else:
            raise ValueError(f'No schema for {key(obj)}')
    print(f'PASS: {len(resources)} resources; Kustomize/Helm rendering; Kubernetes/Flux/Calico schemas; ownership; dependency graph; scoped RBAC; Kata/restricted contexts; Flux network boundaries; secret hygiene.')
    print('NOT VERIFIED: live admission/traffic, image pulls, VM startup, Git reconciliation, age decryption, reinstall and data restore.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, jsonschema.ValidationError, subprocess.CalledProcessError) as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
