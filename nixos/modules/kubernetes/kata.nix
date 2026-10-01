{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.kubernetes;
  kataVersion = "4.2.0";
  # Upstream's static Rust runtime includes QEMU, virtiofsd, and the guest.
  # Keep it immutable; guests cannot supply hypervisor configuration.
  kata = pkgs.stdenvNoCC.mkDerivation {
    pname = "kata-containers-static";
    version = kataVersion;
    src = pkgs.fetchurl {
      url = "https://github.com/kata-containers/kata-containers/releases/download/${kataVersion}/kata-static-${kataVersion}-amd64.tar.zst";
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
  };
  kataConfig = pkgs.runCommand "kata.toml" { } ''
    cp ${kata}/share/defaults/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml "$out"
    chmod u+w "$out"
    sed -i \
      -e 's/^enable_annotations = .*/enable_annotations = []/' \
      -e 's/^default_memory = .*/default_memory = 1024/' \
      -e 's/^overhead_memory = .*/overhead_memory = 256/' \
      -e 's|^firmware = .*|firmware = "${kata}/share/kata-qemu/qemu/bios-256k.bin"|' \
      -e 's/^disable_guest_seccomp = .*/disable_guest_seccomp = false/' \
      "$out"
  '';
  containerdTemplate = pkgs.writeText "config-v3.toml.tmpl" ''
    {{ template "base" . }}
    {{ if not (or .NodeConfig.AgentConfig.CNIBinDir .NodeConfig.AgentConfig.CNIConfDir) }}
    [plugins.'io.containerd.cri.v1.runtime'.cni]
      bin_dirs = ["/var/lib/rancher/k3s/data/cni"]
      conf_dir = "/var/lib/rancher/k3s/agent/etc/cni/net.d"
    {{ end }}
    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata-qemu]
      runtime_type = "io.containerd.kata.v2"
      runtime_path = "${kata}/runtime-rs/bin/containerd-shim-kata-v2"
      privileged_without_host_devices = true
    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata-qemu.options]
      ConfigPath = "${kataConfig}"
  '';

in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "The pinned Kata bundle supports x86_64-linux only.";
      }
    ];
    boot.kernelModules = [
      "vhost_vsock"
      "vhost_net"
      "tun"
    ];
    services.k3s.nodeLabel = [ "homelab/kata=true" ];
    systemd.tmpfiles.rules = [
      "d /var/lib/rancher/k3s/agent/etc/containerd 0755 root root -"
      "L+ /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl - - - - ${containerdTemplate}"
    ];
    systemd.services.k3s.restartTriggers = [
      containerdTemplate
      kataConfig
    ];
  };
}
