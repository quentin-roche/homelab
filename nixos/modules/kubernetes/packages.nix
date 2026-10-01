{ pkgs }:

# Pinned runtime dependencies and the shared Kustomize builder. This file does
# not install cluster resources; the component modules declare their owners.
let
  calicoVersion = "3.32.2";
  fluxVersion = "2.9.5";
in
{
  calico = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/projectcalico/calico/v${calicoVersion}/manifests/calico.yaml";
    sha256 = "a8c828a06a87c629a282ebbc424895b77f3a030251993e41ea400a743675bb02";
  };
  flux = {
    version = fluxVersion;
    install = pkgs.fetchurl {
      url = "https://github.com/fluxcd/flux2/releases/download/v${fluxVersion}/install.yaml";
      sha256 = "cc3dcd743af16215838b6937e1fce83745bf24c0dcc6c59737c59df15429caaf";
    };
  };
  kubernetesSchema = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/kubernetes/kubernetes/v1.35.0/api/openapi-spec/swagger.json";
    sha256 = "483500149ee52ce5753d75f5639101d985bb4f5e902cc05b1ba7627465d62446";
  };

  platformCharts = {
    traefik = pkgs.fetchurl {
      url = "https://traefik.github.io/charts/traefik/traefik-41.6.1.tgz";
      sha256 = "1e65d46bae0ba0baef460a1d82686b50f156372865a3d7d8a85b51c3855b2ef9";
    };
    cert-manager = pkgs.fetchurl {
      url = "https://charts.jetstack.io/charts/cert-manager-v1.21.2.tgz";
      sha256 = "73a56e1728edd6c99f1f31082618c3259d279a76b7ebd3d4bdc5475c2442d34a";
    };
  };

  render =
    {
      name,
      upstream,
      overlay,
    }:
    pkgs.runCommand name { nativeBuildInputs = [ pkgs.kustomize ]; } ''
      cp -rL ${overlay}/. .
      chmod -R u+w .
      cp ${upstream} upstream.yaml
      kustomize build . > "$out"
    '';

}
