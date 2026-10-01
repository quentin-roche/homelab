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
