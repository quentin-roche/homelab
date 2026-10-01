{ pkgs }:
{
  version = "2.9.5";
  install = pkgs.fetchurl {
    url = "https://github.com/fluxcd/flux2/releases/download/v2.9.5/install.yaml";
    sha256 = "cc3dcd743af16215838b6937e1fce83745bf24c0dcc6c59737c59df15429caaf";
  };
  kubernetesSchema = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/kubernetes/kubernetes/v1.35.0/api/openapi-spec/swagger.json";
    sha256 = "483500149ee52ce5753d75f5639101d985bb4f5e902cc05b1ba7627465d62446";
  };
}
