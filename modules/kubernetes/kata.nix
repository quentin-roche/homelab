{ pkgs }:

# Upstream's static Rust runtime bundle includes QEMU, virtiofsd, and the guest.
# Keep the bundle immutable; guests cannot supply hypervisor configuration.
pkgs.stdenvNoCC.mkDerivation {
  pname = "kata-containers-static";
  version = "4.2.0";
  src = pkgs.fetchurl {
    url = "https://github.com/kata-containers/kata-containers/releases/download/4.2.0/kata-static-4.2.0-amd64.tar.zst";
    hash = "sha256-uCiQT6Px5J3dfceZxyyxUDzR53LTVMOYfI1BibKmI6g=";
  };
  nativeBuildInputs = [ pkgs.zstd ];
  unpackPhase = "tar --zstd -xf $src";
  installPhase = ''
    mkdir -p "$out"
    cp -a opt/kata/. "$out/"
    find "$out/share/defaults" -type f -name '*.toml' -exec \
      sed -i "s|/opt/kata|$out|g" {} +
    # QEMU also searches its compiled /opt/kata prefix for boot ROMs.
    mv "$out/bin/qemu-system-x86_64" "$out/bin/qemu-system-x86_64.real"
    cat > "$out/bin/qemu-system-x86_64" <<EOF
    #!${pkgs.runtimeShell}
    exec "$out/bin/qemu-system-x86_64.real" -L "$out/share/kata-qemu/qemu" "\$@"
    EOF
    chmod +x "$out/bin/qemu-system-x86_64"
  '';
  dontFixup = true;
}
