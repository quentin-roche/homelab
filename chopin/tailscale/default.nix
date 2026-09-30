{ config, pkgs, lib, ... }:
let
  namespaceTags = config.homelab.tailnet.namespaceTags;
  # Give each namespace a distinct Headscale owner. Enrollment credentials
  # must never belong to a user that can request more privileged tags.
  tagOwners = lib.foldlAttrs (owners: namespace: tag:
    owners // { ${tag} = (owners.${tag} or []) ++ [ "namespace-${namespace}@" ]; })
    { "tag:chopin" = [ "chopin@" ]; "tag:laptop" = [ "admin@" ]; } namespaceTags;
  policy = pkgs.writeText "headscale-policy.json" (builtins.toJSON (
    (builtins.fromJSON (builtins.readFile ./policy.json)) // { inherit tagOwners; }
  ));
  sidecarScript = pkgs.writeText "tailscale-sidecar.sh" (builtins.readFile ./sidecar.sh);
  image = pkgs.dockerTools.buildLayeredImage {
    name = "chopin/tailscale-sidecar";
    contents = with pkgs; [ tailscale iptables iproute2 busybox cacert ];
    extraCommands = ''
      mkdir -p etc var/run/tailscale var/lib/tailscale enroll
      cp ${sidecarScript} sidecar.sh
      chmod 555 sidecar.sh
    '';
    config = { Entrypoint = [ "/bin/sh" "/sidecar.sh" ]; };
  };
  sidecar = {
    name = "tailscale";
    image = "${image.imageName}:${image.imageTag}";
    imagePullPolicy = "Never";
    restartPolicy = "Always";
    securityContext = { privileged = true; runAsUser = 0; runAsNonRoot = false; };
    env = [{ name = "POD_NAME"; valueFrom.fieldRef.fieldPath = "metadata.name"; }];
    volumeMounts = [
      { name = "tailscale-state"; mountPath = "/var/lib/tailscale"; }
      { name = "tailscale-enrollment"; mountPath = "/enroll"; readOnly = true; }
    ];
    startupProbe = {
      exec.command = [ "/bin/sh" "-c" "tailscale --socket=/var/run/tailscale/tailscaled.sock status --json | grep -q '\"BackendState\": \"Running\"'" ];
      periodSeconds = 2; failureThreshold = 150;
    };
    resources = { requests = { cpu = "25m"; memory = "64Mi"; }; limits.memory = "256Mi"; };
  };
  # JSONPatch keeps other init containers and volumes, and fixes the sidecar
  # template centrally. Namespace-local credentials select the role, not labels.
  cel = value:
    if builtins.isAttrs value then
      "{" + lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${builtins.toJSON k}:dyn(${cel v})") value) + "}"
    else if builtins.isList value then
      "[" + lib.concatMapStringsSep "," (v: "dyn(${cel v})") value + "]"
    else builtins.toJSON value;
  patchExpr = ''
    [
      JSONPatch{op: 'add', path: '/spec/initContainers', value:
        (has(object.spec.initContainers) ? object.spec.initContainers : []) + [dyn(${cel sidecar})]},
      JSONPatch{op: 'add', path: '/spec/volumes', value:
        (has(object.spec.volumes) ? object.spec.volumes : []) + ${cel [
          { name = "tailscale-state"; emptyDir = {}; }
          { name = "tailscale-enrollment"; secret = { secretName = "tailscale-enrollment"; defaultMode = 256; }; }
        ]}}
    ]
  '';
  sidecarValidation = pkgs.writeText "tailscale-validation.json" (builtins.toJSON {
    apiVersion = "v1"; kind = "List"; items = [
      {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "ValidatingAdmissionPolicy";
        metadata.name = "require-tailscale-sidecar";
        spec = {
          failurePolicy = "Fail";
          matchConstraints.resourceRules = [{ apiGroups = [ "" ]; apiVersions = [ "v1" ]; operations = [ "CREATE" "UPDATE" ]; resources = [ "pods" "pods/ephemeralcontainers" ]; }];
          matchConditions = [{ name = "application"; expression = "!(request.namespace in ['kube-system', 'kube-public', 'kube-node-lease'])"; }];
          validations = [{
            message = "Application pods require the fixed administrator-managed Tailscale sidecar.";
            expression = "has(object.spec.initContainers) && object.spec.initContainers.filter(c, c.name == 'tailscale').size() == 1 && object.spec.initContainers.filter(c, c.name == 'tailscale').all(c, c.image == '${sidecar.image}' && c.imagePullPolicy == 'Never' && c.restartPolicy == 'Always' && !has(c.command) && !has(c.args) && !has(c.envFrom) && !has(c.lifecycle) && !has(c.livenessProbe) && !has(c.readinessProbe) && c.env.size() == 1 && c.env[0].name == 'POD_NAME' && has(c.env[0].valueFrom) && c.env[0].valueFrom.fieldRef.fieldPath == 'metadata.name' && c.volumeMounts.size() == 2 && c.volumeMounts[0].name == 'tailscale-state' && c.volumeMounts[0].mountPath == '/var/lib/tailscale' && c.volumeMounts[1].name == 'tailscale-enrollment' && c.volumeMounts[1].mountPath == '/enroll' && c.volumeMounts[1].readOnly && c.startupProbe.exec.command == ['/bin/sh', '-c', ${builtins.toJSON (builtins.elemAt sidecar.startupProbe.exec.command 2)}])";
          }];
        };
      }
      {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "ValidatingAdmissionPolicyBinding";
        metadata.name = "require-tailscale-sidecar";
        spec = { policyName = "require-tailscale-sidecar"; validationActions = [ "Deny" ]; };
      }
    ];
  });
  mutation = pkgs.writeText "tailscale-injection.json" (builtins.toJSON {
    apiVersion = "v1"; kind = "List"; items = [
      {
        apiVersion = "admissionregistration.k8s.io/v1beta1";
        kind = "MutatingAdmissionPolicy";
        metadata.name = "tailscale-sidecar";
        spec = {
          failurePolicy = "Fail";
          reinvocationPolicy = "Never";
          matchConstraints.resourceRules = [{ apiGroups = [ "" ]; apiVersions = [ "v1" ]; operations = [ "CREATE" ]; resources = [ "pods" ]; }];
          matchConditions = [
            { name = "application"; expression = "!(request.namespace in ['kube-system', 'kube-public', 'kube-node-lease'])"; }
            { name = "absent"; expression = "!has(object.spec.initContainers) || !object.spec.initContainers.exists(c, c.name == 'tailscale')"; }
          ];
          mutations = [{ patchType = "JSONPatch"; jsonPatch.expression = patchExpr; }];
        };
      }
      {
        apiVersion = "admissionregistration.k8s.io/v1beta1";
        kind = "MutatingAdmissionPolicyBinding";
        metadata.name = "tailscale-sidecar";
        spec.policyName = "tailscale-sidecar";
      }
    ];
  });
  namespaces = pkgs.writeText "tailnet-namespaces.json" (builtins.toJSON {
    apiVersion = "v1"; kind = "List";
    items = lib.concatMap (name: [
      { apiVersion = "v1"; kind = "Namespace"; metadata = {
          inherit name;
          labels = {
            "pod-security.kubernetes.io/enforce" = "privileged";
            "pod-security.kubernetes.io/audit" = "restricted";
            "pod-security.kubernetes.io/warn" = "restricted";
          };
        };
      }
      { apiVersion = "v1"; kind = "ServiceAccount";
        metadata = { name = "default"; namespace = name; };
        automountServiceAccountToken = false;
      }
    ]) (builtins.attrNames namespaceTags);
  });
in {
  options.homelab.tailnet.namespaceTags = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { applications = "tag:applications"; default = "tag:default"; };
    description = "Administrator-managed namespace to Headscale tag mapping. Matching tag ownership and Headscale users are generated automatically.";
  };
  options.homelab.tailnet.sidecarRevision = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = image.imageTag;
    description = "Include this in workload template annotations to roll pods when the injected sidecar changes.";
  };
  config = {
    services.headscale = {
      enable = true;
      address = "0.0.0.0";
      settings = {
        server_url = "http://192.168.1.82:8080";
        policy = { mode = "file"; path = policy; };
        dns = { magic_dns = true; base_domain = "tail.home.arpa"; override_local_dns = false; };
        # Required by Headscale. The host guard blocks guest access to these
        # public relays; this initial configuration uses direct local UDP paths.
        derp = { urls = [ "https://controlplane.tailscale.com/derpmap/default" ]; auto_update_enabled = false; };
        ephemeral_node_inactivity_timeout = "5m";
      };
    };
    services.tailscale = { enable = true; useRoutingFeatures = "server"; openFirewall = false; };
    services.k3s.manifests."11-tailnet-namespaces".source = namespaces;
    services.k3s.manifests."15-tailscale-injection".source = mutation;
    services.k3s.manifests."16-tailscale-validation".source = sidecarValidation;
    systemd.services.chopin-tailnet-enrollment = {
      description = "Refresh administrator-scoped pod enrollment credentials";
      wantedBy = [ "multi-user.target" ];
      after = [ "headscale.service" "k3s.service" "tailscaled.service" "chopin-retire-calico.service" ];
      requires = [ "headscale.service" "k3s.service" "tailscaled.service" "chopin-retire-calico.service" ];
      path = with pkgs; [ headscale tailscale k3s jq coreutils bash ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; Restart = "on-failure"; RestartSec = "10s"; };
      script = ''
        for attempt in $(seq 1 60); do
          if headscale health >/dev/null 2>&1 && k3s kubectl get mutatingadmissionpolicy tailscale-sidecar >/dev/null 2>&1 && k3s kubectl get namespaces ${lib.escapeShellArgs (builtins.attrNames namespaceTags)} >/dev/null 2>&1; then break; fi
          sleep 2
        done
        headscale health >/dev/null
        k3s kubectl get namespaces ${lib.escapeShellArgs (builtins.attrNames namespaceTags)} >/dev/null
        if ! headscale users list -o json | jq -e '.[] | select(.name == "admin")' >/dev/null; then
          headscale users create admin --email admin@example.invalid >/dev/null
        fi
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (namespace: tag: ''
          if ! headscale users list -o json | jq -e '.[] | select(.name == "namespace-${namespace}")' >/dev/null; then
            headscale users create ${lib.escapeShellArg "namespace-${namespace}"} >/dev/null
          fi
          bash ${./enroll-namespace.sh} ${lib.escapeShellArg namespace} ${lib.escapeShellArg tag}
        '') namespaceTags)}
        if ! tailscale status --json | jq -e '.BackendState == "Running"' >/dev/null || [ "$(tailscale debug prefs | jq -r .ControlURL)" != "http://192.168.1.82:8080" ]; then
          enrollment_dir=$(mktemp -d)
          trap 'rm -rf "$enrollment_dir"' EXIT
          if ! headscale users list -o json | jq -e '.[] | select(.name == "chopin")' >/dev/null; then
            headscale users create chopin >/dev/null
          fi
          owner_id=$(headscale users list -o json | jq -er '.[] | select(.name == "chopin") | .id')
          headscale preauthkeys create --user "$owner_id" --tags tag:chopin -o json | jq -er '.key' > "$enrollment_dir/authkey"
          tailscale up --login-server=http://192.168.1.82:8080 --auth-key="file:$enrollment_dir/authkey" --hostname=chopin --accept-dns=false --netfilter-mode=off
        fi
        # NixOS owns the host firewall; tailscaled must not open its UDP port
        # globally as a side effect of installing its own iptables chains.
        tailscale set --netfilter-mode=off --accept-dns=false
      '';
    };
    systemd.services.chopin-tailnet-refresh = {
      description = "Rotate namespace enrollment keys";
      after = [ "chopin-tailnet-enrollment.service" ];
      requires = [ "chopin-tailnet-enrollment.service" ];
      path = config.systemd.services.chopin-tailnet-enrollment.path;
      script = config.systemd.services.chopin-tailnet-enrollment.script;
      serviceConfig = { Type = "oneshot"; UMask = "0077"; };
    };
    systemd.timers.chopin-tailnet-enrollment = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "12h"; Unit = "chopin-tailnet-refresh.service"; };
    };
    systemd.services.chopin-sidecar-image = {
      description = "Import the immutable Tailscale sidecar image into K3s";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" ];
      requires = [ "k3s.service" ];
      restartTriggers = [ image ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''${pkgs.k3s}/bin/k3s ctr images import ${image}'';
    };
  };
}
