# NixOS VM test: three machines without any outside network.
#   machine  runs the sandbox as an ordinary user
#   web      a web server on ports 80 and 8080, and the name server for web.test and other.test
#   other    a second web server, standing for everything a sandbox should not reach
# Not covered here, because it needs certificates from a public authority: HTTP rules and
# credentials over HTTPS.
{ agent-sandbox }:
{
  name = "agent-sandbox";

  nodes = {
    machine =
      { pkgs, ... }:
      {
        environment.systemPackages = [
          agent-sandbox
          pkgs.bubblewrap # for the one test that runs sandbox.sh without the wrapper
          pkgs.curl
          pkgs.python3
        ];
        users.users.alice.isNormalUser = true;
        boot.kernelModules = [ "tun" ]; # pasta
        networking.dhcpcd.extraConfig = "nohook resolv.conf"; # the test points it at web
        virtualisation.memorySize = 2048;

        # stands for the services on a workstation's loopback
        environment.etc."loopback-service/host-loopback-service".text = "";
        systemd.services.loopback-service = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --bind 127.0.0.1 --directory /etc/loopback-service";
        };
      };

    web =
      { nodes, ... }:
      {
        networking.firewall.allowedTCPPorts = [
          53
          80
          8080
        ];
        networking.firewall.allowedUDPPorts = [ 53 ];
        services.nginx = {
          enable = true;
          virtualHosts.default = {
            default = true;
            listen = [
              {
                addr = "0.0.0.0";
                port = 80;
              }
              {
                addr = "0.0.0.0";
                port = 8080;
              }
            ];
            locations."/".return = ''200 "web\n"'';
            locations."/headers".return = ''200 "authorization=$http_authorization x-api-key=$http_x_api_key\n"'';
          };
        };
        services.dnsmasq = {
          enable = true;
          resolveLocalQueries = false;
          settings = {
            no-resolv = true;
            address = [
              "/web.test/${nodes.web.networking.primaryIPAddress}"
              "/other.test/${nodes.other.networking.primaryIPAddress}"
            ];
          };
        };
      };

    other = {
      networking.firewall.allowedTCPPorts = [ 80 ];
      services.nginx = {
        enable = true;
        virtualHosts.default = {
          default = true;
          locations."/".return = ''200 "other\n"'';
        };
      };
    };
  };

  testScript =
    { nodes, ... }:
    ''
      import shlex

      WEB_IP = "${nodes.web.networking.primaryIPAddress}"
      OTHER_IP = "${nodes.other.networking.primaryIPAddress}"


      def alice(command):
          return "su - alice -c " + shlex.quote(command)


      def sandbox(options, script, cwd="~/projects/demo", env=""):
          """Command line that runs a shell snippet in the sandbox, as alice, started in cwd."""
          return alice(f"cd {cwd} && {env} agent-sandbox {options} -- sh -c {shlex.quote(script)} 2>&1")


      def reachable(output):
          return sorted(line.split("=")[0] for line in output.splitlines() if line.endswith("=yes"))


      def store_path(output):
          return [line for line in output.splitlines() if line.startswith("/nix/store/")][0]


      # prints NAME=yes or NAME=no for each destination
      PROBE = (
          'reach() { if curl -sf -o /dev/null --max-time 5 "$2"; then echo "$1=yes"; else echo "$1=no"; fi; }; '
          "reach web http://web.test/; reach port-8080 http://web.test:8080/; reach other http://other.test/; "
          f"reach other-by-address http://{OTHER_IP}/; reach host-loopback http://127.0.0.1:8000/"
      )
      # a server of the sandbox's own on the port the host's loopback service uses
      OWN_SERVER = "; python3 -m http.server 8000 --bind 127.0.0.1 >/dev/null 2>&1 & sleep 2; curl -s http://127.0.0.1:8000/ | grep -c in-demo"

      start_all()
      web.wait_for_unit("nginx.service")
      web.wait_for_unit("dnsmasq.service")
      other.wait_for_unit("nginx.service")
      machine.wait_for_unit("multi-user.target")
      machine.succeed(f"rm -f /etc/resolv.conf && echo 'nameserver {WEB_IP}' > /etc/resolv.conf")
      machine.wait_until_succeeds("curl -sf http://web.test/ | grep -x web")
      machine.succeed("curl -sf http://other.test/ | grep -x other")
      machine.succeed("curl -sf http://127.0.0.1:8000/ | grep host-loopback-service")

      machine.succeed(alice(
          "mkdir -p ~/projects/demo ~/projects/second ~/scratch ~/projects/.agents-private-home/.cache"
          " && echo host-only > ~/host-file && echo second > ~/projects/second/file"
          " && echo template > ~/projects/.agents-private-home/from-template"
          " && echo junk > ~/projects/.agents-private-home/.cache/junk"
          " && touch ~/projects/demo/in-demo"
      ))

      with subtest("the sandbox shares the directory it is started in and nothing else"):
          out = machine.succeed(sandbox("", "pwd; touch made-inside; ls ~/host-file ~/projects/second 2>&1; true"))
          assert "/home/alice/projects/demo" in out, out
          assert out.count("No such file") == 2, out
          machine.succeed("test -e /home/alice/projects/demo/made-inside")
          machine.fail(alice("cd ~ && agent-sandbox true"))
          machine.fail(alice("cd ~/projects && agent-sandbox true"))
          machine.fail(alice("cd ~/scratch && agent-sandbox true"))
          machine.fail(alice("cd ~ && agent-sandbox --here true"))
          machine.succeed(alice("cd ~/scratch && agent-sandbox --here true"))

      with subtest("every directory has a home of its own, copied from the template"):
          out = machine.succeed(sandbox("", "cat ~/from-template; test -e ~/.cache/junk && echo cache=yes; echo from-demo > ~/note"))
          assert "template" in out and "cache=yes" not in out, out
          assert "from-demo" in machine.succeed(sandbox("", "cat ~/note"))
          assert "from-demo" not in machine.succeed(sandbox("", "cat ~/note 2>&1; true", cwd="~/projects/second"))
          out = machine.succeed(sandbox("--shared-home", "test -e ~/.cache/junk && echo cache=yes; cat ~/note 2>&1; echo x > ~/added; true"))
          assert "cache=yes" in out and "from-demo" not in out, out
          machine.succeed("test -e /home/alice/projects/.agents-private-home/added")
          machine.succeed("ls /home/alice/projects/.agents-homes | grep '^demo\\.' && ls /home/alice/projects/.agents-homes | grep '^second\\.'")

      with subtest("its own tools are not taken from the project"):
          machine.succeed(alice(
              "mkdir -p ~/projects/demo/bin && for t in realpath bwrap sed sha256sum python3; do"
              " printf '#!/bin/sh\\ntouch /home/alice/planted-ran\\nexit 1\\n' > ~/projects/demo/bin/$t; chmod +x ~/projects/demo/bin/$t; done"
          ))
          machine.succeed(sandbox("", "true", env="PATH=/home/alice/projects/demo/bin:$PATH"))
          # the wrapper names the tools; sandbox.sh alone has to ignore the planted ones as well
          machine.succeed(alice("cd ~/projects/demo && PATH=/home/alice/projects/demo/bin:$PATH sh ${agent-sandbox}/share/agent-sandbox/sandbox.sh true"))
          machine.fail("test -e /home/alice/planted-ran")
          machine.succeed("rm -r /home/alice/projects/demo/bin")

      with subtest("without options the network is the host's"):
          out = machine.succeed(sandbox("", PROBE))
          assert reachable(out) == ["host-loopback", "other", "other-by-address", "port-8080", "web"], out

      with subtest("an allowlist admits only what it names"):
          out = machine.succeed(sandbox("--nix-store none --net-allow web.test:80", PROBE))
          assert reachable(out) == ["web"], out

      with subtest("a private network has a loopback of its own"):
          out = machine.succeed(sandbox("--private-net", PROBE + OWN_SERVER))
          assert reachable(out) == ["other", "other-by-address", "port-8080", "web"], out
          assert out.strip().endswith("1"), out
          machine.succeed(alice("cd ~/projects/demo && (agent-sandbox --private-net --forward 9000 -- python3 -m http.server 9000 --bind 127.0.0.1 >/dev/null 2>&1 &)"))
          machine.wait_until_succeeds("curl -sf http://127.0.0.1:9000/ | grep in-demo", timeout=60)
          machine.succeed("pkill -u alice -f 'http.server 9000'")

      with subtest("allowlist and private network together"):
          out = machine.succeed(sandbox("--private-net --nix-store none --net-allow web.test:80", PROBE + OWN_SERVER))
          assert reachable(out) == ["web"], out
          assert out.strip().endswith("1"), out

      with subtest("learning writes a preset, which can then be enforced"):
          machine.succeed(sandbox("--net-learn learned", f"curl -s -o /dev/null http://web.test/; curl -s -o /dev/null http://{OTHER_IP}/; true"))
          preset = machine.succeed("cat /home/alice/.config/agent-sandbox/presets/learned")
          assert "--net-allow web.test:80" in preset and f"--net-allow {OTHER_IP}:80" in preset, preset
          out = machine.succeed(sandbox("--private-net --nix-store none --preset learned", PROBE))
          assert reachable(out) == ["other-by-address", "web"], out

      with subtest("a credential is attached on the way out and never enters the sandbox"):
          machine.succeed(alice("echo s3cret-from-file > ~/key"))
          out = machine.succeed(sandbox(
              "--nix-store none --http-allow 'GET web.test/*'"
              " --credential filekey=file:/home/alice/key --http-auth 'GET web.test/headers/file bearer filekey'"
              " --credential envkey=env:API_KEY --http-auth 'GET web.test/headers/env header:x-api-key envkey'",
              "curl -s http://web.test/headers/file; curl -s http://web.test/headers/env; echo inside=$API_KEY;"
              " curl -s -o /dev/null -w 'post=%{http_code}\\n' -X POST http://web.test/; echo leaked=$(env | grep -c s3cret)",
              env="API_KEY=s3cret-from-env AGENT_SANDBOX_ENV=API_KEY",
          ))
          assert "authorization=Bearer s3cret-from-file" in out, out
          assert "x-api-key=s3cret-from-env" in out, out
          assert "inside=placeholder" in out and "post=403" in out and "leaked=0" in out, out

      with subtest("under an allowlist nix works on a private store"):
          system = machine.succeed("readlink -f /run/current-system").strip()
          machine.succeed(f"nix-store --check-validity {system}")
          out = machine.succeed(sandbox(
              "--net-allow web.test:80",
              f"cd /tmp; nix-store --check-validity {system} && echo host-paths=valid; echo data > f; nix-store --add f; NIX_REMOTE=daemon nix-store --add f 2>&1 | tail -1",
          ))
          assert "host-paths=valid" in out and "daemon-socket" in out, out
          machine.fail(f"test -e {store_path(out)}")  # it is in the sandbox's overlay, not in the host's store

          out = machine.succeed(sandbox("--net-allow web.test:80 --nix-store disk", "cd /tmp; echo kept > f; nix-store --add f"))
          kept = store_path(out)
          machine.succeed(sandbox("--net-allow web.test:80 --nix-store disk", f"nix-store --check-validity {kept} && grep -x kept {kept}"))
          machine.fail(f"test -e {kept}")

          out = machine.succeed(sandbox("--net-allow web.test:80 --nix-store daemon", "cd /tmp; echo shared > f; nix-store --add f"))
          machine.succeed(f"test -e {store_path(out)}")

      with subtest("a dry run only prints"):
          machine.succeed(alice("mkdir ~/projects/untouched"))
          out = machine.succeed(alice("cd ~/projects/untouched && agent-sandbox --private-net --dry-run true"))
          assert out.startswith("bwrap ") and "pasta" in out, out
          machine.fail("ls /home/alice/projects/.agents-homes | grep untouched")
    '';
}
