{
  description = "agent-sandbox: run a coding agent in a bubblewrap sandbox scoped to one directory";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux"; # sandlock.nix wraps the upstream x86_64 release binary
      pkgs = nixpkgs.legacyPackages.${system};

      sandlock = pkgs.callPackage ./sandlock.nix { };

      # Everything sandbox.sh starts on the host side. The script takes its tools from here
      # before anything in PATH, and hands PATH itself to the sandbox untouched.
      tools = [
        pkgs.bash
        pkgs.bubblewrap
        pkgs.coreutils
        pkgs.gnused
        pkgs.passt
        pkgs.python3
        pkgs.util-linux
        sandlock
      ];

      # on its own, so that the package only changes when the script does
      script = builtins.path {
        path = ./sandbox.sh;
        name = "sandbox.sh";
      };

      agent-sandbox =
        pkgs.runCommand "agent-sandbox"
          {
            meta = {
              description = "Run a coding agent in a bubblewrap sandbox scoped to one directory";
              mainProgram = "agent-sandbox";
              platforms = [ system ];
            };
          }
          ''
            install -Dm644 ${script} $out/share/agent-sandbox/sandbox.sh
            mkdir -p $out/bin
            cat > $out/bin/agent-sandbox <<EOF
            #!${pkgs.bash}/bin/bash
            export AGENT_SANDBOX_TOOLS=${pkgs.lib.makeBinPath tools}
            exec ${pkgs.bash}/bin/bash $out/share/agent-sandbox/sandbox.sh "\$@"
            EOF
            chmod +x $out/bin/agent-sandbox
          '';
    in
    {
      # nix run PATH-OF-THIS-FLAKE -- [options] [command]
      packages.${system} = {
        inherit agent-sandbox sandlock;
        default = agent-sandbox;
      };

      # nix flake check: boots three VMs and runs the sandbox in one of them
      checks.${system}.vm = pkgs.testers.runNixOSTest (import ./tests/vm.nix { inherit agent-sandbox; });
    };
}
