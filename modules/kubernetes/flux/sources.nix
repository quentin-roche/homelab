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
  podinfoChart = pkgs.fetchurl {
    url = "https://stefanprodan.github.io/podinfo/podinfo-6.15.0.tgz";
    sha256 = "5ca7896889b539e04cdad4df2093ff1ff7576295e7e3ef90a1e1845e3a334d75";
  };
}
