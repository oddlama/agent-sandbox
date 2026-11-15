# sandlock (https://github.com/multikernel/sandlock) from the upstream release binary,
# patched for NixOS. sandbox.sh runs commands under it when given an allowlist; the flake
# builds it as .#sandlock and puts it on the script's tool path.
{
  pkgs ? import <nixpkgs> { },
}:
pkgs.stdenv.mkDerivation rec {
  pname = "sandlock-bin";
  version = "0.9.1";

  src = pkgs.fetchurl {
    url = "https://github.com/multikernel/sandlock/releases/download/v${version}/sandlock-x86_64-unknown-linux-gnu.tar.gz";
    hash = "sha256-lAa1RM58+OLviMXxPM2HvQtpQow/3rlLI3xyh0N2mrQ=";
  };
  sourceRoot = ".";

  nativeBuildInputs = [ pkgs.autoPatchelfHook ];
  buildInputs = [ pkgs.stdenv.cc.cc.lib ];
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    install -Dm755 sandlock $out/bin/sandlock
  '';

  meta = {
    description = "Process sandbox built on Landlock and seccomp";
    homepage = "https://github.com/multikernel/sandlock";
    license = pkgs.lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    mainProgram = "sandlock";
  };
}
