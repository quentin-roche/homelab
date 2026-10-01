{ pkgs }:

# Build a local overlay against a checksum-pinned upstream manifest.
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
''
