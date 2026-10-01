{ pkgs }:
{
  calico = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/calico.yaml";
    sha256 = "a8c828a06a87c629a282ebbc424895b77f3a030251993e41ea400a743675bb02";
  };
}
