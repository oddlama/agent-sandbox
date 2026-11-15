# agent-sandbox

`agent-sandbox` runs a coding agent (or any other command) in a
[bubblewrap](https://github.com/containers/bubblewrap) sandbox that is scoped to
a single project directory. The agent can write to the directory it was started
in and to a home of its own, sees the system read-only and nothing else.
Optionally you can restrict its network access to an allowlist and keep your
API keys out of the sandbox entirely.

- 📁 **One directory, nothing else** - the rest of `~/projects`, your real home and all host sockets (Wayland, D-Bus, ssh-agent, ...) are out of reach
- 🏠 **A home per project** copied from a template, so an agent can't leave anything behind for sessions in other projects
- 🌐 **Network allowlist** by host and port or by HTTP method and path, enforced by [sandlock](https://github.com/multikernel/sandlock)
- 🔑 **API keys stay outside** and are attached to matching requests on their way out
- 🔌 **Private network namespace** via [pasta](https://passt.top) so the host's loopback services can't be reached
- 🎓 **Learn mode** that records which hosts a session talks to and turns them into a preset
- ❄️ **Nix keeps working** under an allowlist through a private overlay store, without access to the host's daemon

## 📦 Usage

Start it in the directory you want to hand to the agent. The directory must be
inside `~/projects`, pass `--here` for anything else below `~` or `/tmp`.

```sh
mkdir -p ~/projects/.agents-private-home  # Template home, only needed once
cd ~/projects/my-project
nix run github:oddlama/agent-sandbox -- claude
```

Without a command you get a shell. The flake pins all required tools
(bubblewrap, sandlock, pasta, ...), so there is nothing else to install. To have
it around permanently, add the package to your system:

```nix
inputs.agent-sandbox.url = "github:oddlama/agent-sandbox";
# ...
environment.systemPackages = [ inputs.agent-sandbox.packages.x86_64-linux.default ];
```

Run `agent-sandbox --help` for the complete reference, or add `--dry-run` to see
the resulting bwrap command line.

## 🏠 What the agent sees

| Path | Access |
|---|---|
| The directory you started it in | read-write |
| `$HOME` | read-write, separate for each sandboxed directory |
| `/nix`, `/etc`, `/usr`, `/bin` | read-only |
| `/tmp`, `/run`, `/dev`, `/proc` | fresh and private |
| Everything else | not visible |

Homes live in `~/projects/.agents-homes` and start out as a copy of the template
home (without `.cache`). Changes to the template don't propagate to existing
homes. Use `--shared-home` to run on the template itself, for example to log in
once for all future projects.

Only a fixed set of environment variables is passed through, add more via
`AGENT_SANDBOX_ENV="FOO BAR"`. GPU devices are only visible with `--gpu`.

## 🌐 Network

By default the network is open and shared with the host. These options change
that:

| Option | Effect |
|---|---|
| `--net-allow HOST[:PORT,...]` | Only allow the given destinations (hostname, IP or CIDR) |
| `--net-allow-bind PORTS` | Allow listening on TCP ports under an allowlist (not needed with `--private-net`) |
| `--http-allow`, `--http-deny "METHOD HOST/PATH"` | Filter HTTP requests by method and path |
| `--credential`, `--http-auth` | Attach a secret to matching requests |
| `--private-net` | Own network namespace, the host's loopback is unreachable |
| `--forward PORTS` | Expose TCP ports of a private network on the host's `127.0.0.1` |
| `--net-learn NAME` | Record all contacted hosts and append them to preset `NAME` |
| `--preset NAME` | Insert the options from `~/.config/agent-sandbox/presets/NAME` |

Hostnames of an allowlist are resolved once at start and pinned in `/etc/hosts`,
everything else including DNS is refused. The simplest way to get an allowlist
is to let a session record it. Review the result before using it though, it
contains whatever the session did:

```sh
agent-sandbox --net-learn claude -- claude
agent-sandbox --private-net --preset claude -- claude
```

A preset is just a list of options, one per line:

```sh
# ~/.config/agent-sandbox/presets/claude
--net-allow api.anthropic.com:443
--net-allow github.com:22,443
```

To keep a key out of the sandbox, let the proxy add it instead:

```sh
agent-sandbox --net-allow api.anthropic.com:443 \
  --credential anthropic=env:ANTHROPIC_API_KEY \
  --http-auth "* api.anthropic.com/* header:x-api-key anthropic" \
  -- claude
```

HTTP rules and credentials route all traffic on ports 80 and 443 through
sandlock's proxy, which decrypts HTTPS using a CA generated for that run. The CA
bundle and `NODE_EXTRA_CA_CERTS` are adjusted inside the sandbox, software with
pinned certificates will refuse to connect.

## ❄️ Nix

The host's nix daemon would happily fetch anything on behalf of the agent, so
under an allowlist it is not reachable. Instead `--nix-store` selects what nix
inside the sandbox works on:

| Mode | Description |
|---|---|
| `ram` (default) | Private overlay over `/nix/store`, kept in memory and gone on exit |
| `disk` | Same, but kept in `~/projects/.agents-nix-store`. Only one sandbox at a time |
| `daemon` | The host's daemon. Not covered by the allowlist! |
| `none` | Nix commands fail |

The private store sees everything in the host's store and downloads through the
allowlist, so remember to allow `cache.nixos.org:443`. Builds run without nix's
own build sandbox.

## ⚠️ Caveats

- Requires `x86_64-linux` with unprivileged user namespaces. Allowlists additionally need Linux 6.12 or newer
- Under an allowlist file- and process-heavy workloads run 2-3x slower, `ps` and `top` don't work, and `ptrace` as well as nested namespaces are denied
- Allowlists filter by IP address. Allowing a host on a shared CDN also allows everything else served from the same addresses
- A copied home includes its logins. If your agent rotates its tokens, other projects may have to log in again

## 🧪 Tests

`nix flake check` boots three NixOS VMs without outside network and runs the
sandbox in one of them.
