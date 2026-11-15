#!/bin/sh
# agent-sandbox: run an agent (or any command) in a bubblewrap sandbox scoped to ONE directory.
#
# The sandbox shares the directory it is started in, read-write, and nothing else of
# ~/projects: start it in the top directory of a project (for a repository with sibling
# worktrees, their common parent). That directory has to be inside ~/projects unless --here
# is given.
#
# Run it with "nix run PATH-OF-THIS-FLAKE -- [options] [command]", which brings bwrap, sandlock,
# pasta and the other tools along, or directly as ./sandbox.sh with those tools on PATH.
#
# Usage: agent-sandbox [options] [--] [command [args...]]   (default command: bash)
#   --gpu      expose GPU devices (/dev/dri, /dev/nvidia*) and /run/opengl-driver
#   --here     allow a directory outside ~/projects (below ~ or /tmp), for one-offs
#   --shared-home
#              use the template home itself, read-write, instead of this directory's own home
#   --preset NAME
#              insert the options stored in ~/.config/agent-sandbox/presets/NAME at this point
#   --dry-run  print the bwrap command line instead of running it
#
#  Network (without any of these the network is open and shared with the host):
#   --net-allow SPEC
#              restrict outbound network to SPEC (repeatable).
#              SPEC is HOST[:PORT[,PORT...]]: HOST is a hostname, IP or CIDR, no port means all
#              ports, and a tcp:// or udp:// prefix pins the protocol. Examples:
#              api.anthropic.com:443   github.com:22,443   127.0.0.1:5432
#   --net-allow-bind PORTS
#              with an allowlist: TCP ports the sandbox may listen on, e.g. 3000,8000-8010 or
#              '*' (default: none; with --private-net: all)
#   --http-allow RULE, --http-deny RULE
#              allow or deny HTTP requests by "METHOD HOST/PATH", e.g. "GET api.github.com/*" or
#              "* api.anthropic.com/v1/*"; deny rules win. Allowed hosts become reachable.
#   --credential NAME=env:VAR | NAME=file:PATH
#              a secret taken from the host's environment or a host file. The sandbox never
#              sees it; --http-auth attaches it to matching requests on their way out. If VAR
#              is passed through with AGENT_SANDBOX_ENV, the sandbox finds the word
#              "placeholder" in it, for clients that insist on having a key.
#   --http-auth "METHOD HOST/PATH KIND NAME"
#              attach credential NAME to matching requests. KIND is bearer, basic:USER,
#              header:HEADERNAME or query:PARAM, e.g. "* api.anthropic.com/* header:x-api-key
#              anthropic". It replaces whatever placeholder the client sends itself.
#   --private-net
#              give the sandbox its own network namespace (needs pasta and python3): loopback
#              is the sandbox's own, so the host's loopback services are out of reach and
#              servers inside are invisible outside.
#   --forward PORTS
#              with --private-net: let the host reach these TCP ports of the sandbox on its own
#              127.0.0.1, e.g. 3000 or 8000-8010
#   --net-learn NAME
#              run with --private-net and an open network, record every host the sandbox
#              contacts and append them as --net-allow lines to preset NAME. Review it before
#              use: the list is whatever the session did, wanted or not. What the host's nix
#              daemon downloads for the sandbox is not seen.
#   --nix-store ram|disk|daemon|none
#              with an allowlist: what nix inside the sandbox works on (default: ram)
#                ram     a private store kept in memory, gone when the sandbox exits
#                disk    a private store kept in $AGENT_SANDBOX_NIX across sessions; only one
#                        sandbox can use it at a time
#                daemon  the host's nix daemon (also: --allow-nix-daemon). It downloads and
#                        builds with unfiltered network access, so an agent that tries can
#                        reach any host through it.
#                none    nothing: nix commands fail
#
# Homes: every sandboxed directory has its own home in $AGENT_SANDBOX_HOMES, so nothing an
# agent writes to its home in one project is seen in another. A new one starts as a copy of the
# template home $AGENT_SANDBOX_HOME (without .cache). Later changes to the template do not
# reach existing homes; delete a project's home to start it over. --shared-home runs on the
# template itself: use it to log in or install things once for all future projects.
#
# Presets: one option per line as on the command line (--net-allow github.com:22,443), blank
# lines and # comments allowed. They are parsed, never executed.
#
# Allowlist: with --net-allow or --http-allow the command runs under sandlock
# (https://github.com/multikernel/sandlock) inside the bwrap sandbox. Hostnames
# are resolved once at start and pinned in a synthetic /etc/hosts; a seccomp supervisor refuses
# every other destination, including DNS, the host's loopback services and the nix daemon.
# Without --private-net loopback is the host's: allowing 127.0.0.1:PORT reaches whatever listens
# there on the host. sandlock also denies ptrace and nested namespaces and virtualizes parts of
# /proc (procps ps/top fail under it), and file- and process-heavy work runs slower.
#
# HTTP rules: with any --http-allow/--http-deny, all traffic to ports 80 and 443 passes through
# sandlock's proxy, which decrypts HTTPS with a certificate authority made up for this run. The
# system CA bundle and NODE_EXTRA_CA_CERTS are adjusted inside the sandbox so that common
# clients trust it; software with its own or pinned certificates will refuse. Hosts given with
# --net-allow stay fully allowed.
#
# Nix under the allowlist: the host's nix daemon would fetch anything on the agent's behalf, so
# nix gets a private store instead: a writable overlay over /nix/store plus a snapshot of the
# host's nix database taken at start (python3 needed). Everything in the host store is usable,
# additions stay in the overlay, and nix's own downloads obey the allowlist, so allow
# cache.nixos.org:443 and whatever else it should fetch from. Builds run without nix's build
# sandbox (it cannot nest here), nix-collect-garbage does not work, and what the host store
# gains or loses after the start is only picked up by the next start. To reclaim the space of
# --nix-store disk while no sandbox uses it: chmod -R u+rwx DIR && rm -rf DIR
#
# Environment:
#   AGENT_SANDBOX_PROJECTS  projects directory (default: ~/projects)
#   AGENT_SANDBOX_HOME      template for the agents' homes (default: ~/projects/.agents-private-home)
#   AGENT_SANDBOX_HOMES     the sandboxes' homes (default: ~/projects/.agents-homes)
#   AGENT_SANDBOX_NIX       store of --nix-store disk (default: ~/projects/.agents-nix-store)
#   AGENT_SANDBOX_ENV       extra variable names to pass through, space separated
#
# Security notes:
# * Everything in the sandboxed directory and in its home is agent-writable. The script reads
#   none of it. The directories it mounts from the host side (the homes, the nix store) and
#   the presets have to be where no sandbox can write, and it refuses to start otherwise.
# * The script's own tools must not come from a place an agent can write to. Run through the
#   flake, they come from the nix store. Otherwise they are looked up in PATH, ignoring entries
#   inside ~/projects, the directory being sandboxed, the agents' homes or /tmp; start the
#   script by its path then, since it cannot protect the lookup of its own name.
# * --net-allow filters by IP address: allowing a host on a shared CDN also admits whatever
#   else is served from the same addresses.

# shellcheck shell=bash
# /bin/sh starts this script, not "env bash": nothing may be looked up in PATH before PATH is
# cleaned below. It still needs bash, which /bin/sh is on NixOS; elsewhere use /bin/bash.
if [ -z "${BASH_VERSION-}" ]; then exec /bin/bash "$0" "$@"; fi
set +o posix
shopt -u inherit_errexit # sh mode leaves this on
set -euo pipefail
shopt -s nullglob

die()  { printf 'sandbox: %s\n' "$*" >&2; exit 1; }
info() { printf 'sandbox: %s\n' "$*" >&2; }

PROJECTS=${AGENT_SANDBOX_PROJECTS:-$HOME/projects}
AGENT_HOME=${AGENT_SANDBOX_HOME:-$PROJECTS/.agents-private-home}
HOMES=${AGENT_SANDBOX_HOMES:-$PROJECTS/.agents-homes}
NIX_DIR=${AGENT_SANDBOX_NIX:-$PROJECTS/.agents-nix-store}
PRESETS=${XDG_CONFIG_HOME:-$HOME/.config}/agent-sandbox/presets

# The script's own tools, bwrap included, must not come from a directory that a sandbox can
# write to: a planted "realpath" would run outside the sandbox. The flake's wrapper names the
# tools' directories in AGENT_SANDBOX_TOOLS; PATH follows. An entry is dropped if any directory
# on the way to it is at or below one a sandbox can write: ~/projects (any directory in it may
# be shared with one), the directory being sandboxed now, the agents' homes, the nix store
# directory, a world-writable temp directory. Only builtins run here. The sandbox itself still
# gets the unmodified PATH.
HOST_PATH=$PATH
clean_path() ( # clean_path LIST
  writable=()
  for d in "$PWD" "$PROJECTS" "$AGENT_HOME" "$HOMES" "$NIX_DIR" /tmp /var/tmp /dev/shm; do
    cd -P -- "$d" 2>/dev/null && writable+=("$PWD")
  done
  sandbox_writable() { # $1: a physical directory
    local d=$1 w
    while [[ $d == /?* ]]; do
      for w in "${writable[@]}"; do [[ $d == "$w" ]] && return 0; done
      d=${d%/*}
    done
    return 1
  }
  IFS=: read -ra entries <<<"$1"
  trusted=()
  for e in "${entries[@]}"; do
    [[ $e == /* ]] || continue # relative and empty entries mean the current directory
    IFS=/ read -ra parts <<<"$e"
    p='' ok=1
    for part in "${parts[@]}"; do
      [[ -n $part ]] || continue
      p+=/$part
      cd -P -- "$p" 2>/dev/null || break # what does not exist yet can only appear in a trusted directory
      if sandbox_writable "$PWD"; then ok=0; break; fi
    done
    ((ok)) && trusted+=("$e")
  done
  IFS=:
  printf '%s' "${trusted[*]}"
)
PATH=$(clean_path "${AGENT_SANDBOX_TOOLS:+$AGENT_SANDBOX_TOOLS:}$PATH")
[[ -n $PATH ]] || die "every directory in PATH is writable by a sandbox" # an empty PATH would mean the current directory

load_preset() { # load_preset NAME -> preset_opts
  local f=$PRESETS/$1 line
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--preset: bad name '$1'"
  ((++presets <= 20)) || die "--preset $1: presets nest too deeply"
  [[ -f $f ]] || die "no preset $f"
  preset_opts=()
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line#"${line%%[![:space:]]*}"} line=${line%"${line##*[![:space:]]}"}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == --?* ]] || die "$f: not an option: $line"
    if [[ $line =~ ^([^[:space:]]+)[[:space:]]+(.*)$ ]]; then
      preset_opts+=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
    else
      preset_opts+=("$line")
    fi
  done <"$f"
}

gpu=0 here=0 dry=0 shared_home=0 private_net=0 presets=0 nix_store='' learn=''
net_allow=() net_bind=() http_allow=() http_deny=() http_auth=() credentials=() forwards=()
while (($#)); do
  case $1 in
    --gpu) gpu=1 ;;
    --here) here=1 ;;
    --shared-home) shared_home=1 ;;
    --private-net) private_net=1 ;;
    --allow-nix-daemon) nix_store=daemon ;;
    --net-allow=* | --net-allow-bind=* | --http-allow=* | --http-deny=* | --http-auth=* | --credential=* | --forward=* | --net-learn=* | --nix-store=* | --preset=*)
      set -- "${1%%=*}" "${1#*=}" "${@:2}"
      continue
      ;;
    --net-allow | --net-allow-bind | --http-allow | --http-deny | --http-auth | --credential | --forward | --net-learn | --nix-store | --preset)
      [[ -n ${2-} && $2 != -* ]] || die "$1 needs an argument (see --help)"
      case $1 in
        --net-allow) net_allow+=("$2") ;;
        --net-allow-bind) net_bind+=("$2") ;;
        --http-allow) http_allow+=("$2") ;;
        --http-deny) http_deny+=("$2") ;;
        --http-auth) http_auth+=("$2") ;;
        --credential) credentials+=("$2") ;;
        --forward) forwards+=("$2") ;;
        --net-learn) learn=$2 ;;
        --nix-store) nix_store=$2 ;;
        --preset)
          load_preset "$2"
          set -- "${preset_opts[@]}" "${@:3}"
          continue
          ;;
      esac
      shift
      ;;
    -n | --dry-run) dry=1 ;;
    -h | --help) sed -n '2,/^$/{/^$/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) break ;;
  esac
  shift
done
(($#)) || set -- bash

need() { # need TOOL WHY -> absolute path of a tool from the cleaned PATH
  local p
  p=$(command -v -- "$1") && [[ $p == /* ]] || die "$2 needs $1 on PATH"
  # resolve the directory (in /nix/store it is visible inside the sandbox too) but keep the name:
  # cp, pasta and others are links to one program that looks at how it was called
  printf '%s/%s' "$(realpath -e -- "${p%/*}")" "${p##*/}"
}

# nix: empty without an allowlist (the host's daemon is reachable as usual), else the --nix-store mode
SANDLOCK='' PYTHON='' PASTA='' nix='' http=0
if ((${#net_allow[@]} + ${#http_allow[@]})); then
  # any HTTP rule or credential puts sandlock's proxy in the path
  ((${#http_allow[@]} + ${#http_deny[@]} + ${#http_auth[@]})) && http=1
  SANDLOCK=$(need sandlock "an allowlist (https://github.com/multikernel/sandlock)")
  nix=${nix_store:-ram}
  case $nix in
    ram | disk)
      PYTHON=$(need python3 "--nix-store $nix (or pass --nix-store none)")
      [[ $nix == ram ]] || need flock "--nix-store disk" >/dev/null
      ;;
    daemon | none) ;;
    *) die "--nix-store must be ram, disk, daemon or none" ;;
  esac
else
  ((${#net_bind[@]} + ${#http_deny[@]} + ${#http_auth[@]} + ${#credentials[@]} == 0)) ||
    die "--net-allow-bind, --http-deny, --http-auth and --credential only work together with --net-allow or --http-allow"
  [[ -z $nix_store || $nix_store == daemon ]] || die "--nix-store only works together with --net-allow or --http-allow"
fi
if [[ -n $learn ]]; then
  [[ $learn =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "--net-learn: bad preset name '$learn'"
  [[ -z $SANDLOCK ]] || die "--net-learn records an open network: leave out --net-allow and --http-allow"
  ((${#forwards[@]} == 0)) || die "--net-learn cannot be combined with --forward"
  private_net=1
fi
if ((private_net)); then
  PASTA=$(need pasta "--private-net")
  [[ -n $PYTHON ]] || PYTHON=$(need python3 "--private-net")
  for f in "${forwards[@]}"; do [[ $f =~ ^[0-9][0-9,:~-]*$ ]] || die "--forward: bad ports '$f'"; done
else
  ((${#forwards[@]} == 0)) || die "--forward only works together with --private-net"
fi
# credentials: NAME=env:VAR or NAME=file:PATH; the secret travels on a descriptor, never on a command line
cred_names=() cred_sources=() cred_env=()
for c in "${credentials[@]}"; do
  [[ $c =~ ^([A-Za-z_][A-Za-z0-9_-]*)=(env|file):(.+)$ ]] || die "--credential: expected NAME=env:VAR or NAME=file:PATH, got '$c'"
  name=${BASH_REMATCH[1]} kind=${BASH_REMATCH[2]} src=${BASH_REMATCH[3]}
  if [[ $kind == env ]]; then
    [[ $src =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -v $src ]] || die "--credential $name: environment variable $src is not set"
    cred_env+=("$src")
  else
    [[ -f $src && -r $src ]] || die "--credential $name: cannot read $src"
  fi
  cred_names+=("$name") cred_sources+=("$kind:$src")
done

PROJECTS=$(realpath -m -- "$PROJECTS")
AGENT_HOME=$(realpath -m -- "$AGENT_HOME")
HOMES=$(realpath -m -- "$HOMES")
NIX_DIR=$(realpath -m -- "$NIX_DIR")
PRESETS=$(realpath -m -- "$PRESETS")
ROOT=$(realpath -e -- "$PWD")
[[ -d $AGENT_HOME ]] || die "agent home $AGENT_HOME does not exist"
[[ $ROOT != *$'\n'* && $ROOT != *$'\t'* ]] || die "refusing paths with tabs/newlines"

below() { [[ $1 == "$2"/* ]]; } # $1 strictly below $2
if ((here)); then
  below "$ROOT" "$HOME" || below "$ROOT" /tmp || die "--here only works below $HOME or /tmp"
  [[ ${ROOT#"$HOME"/} != .* ]] || die "--here refuses hidden directories in $HOME"
else
  [[ $ROOT != "$PROJECTS" ]] || die "start this in a directory inside $PROJECTS: $PROJECTS itself is never shared"
  below "$ROOT" "$PROJECTS" || die "$ROOT is not inside $PROJECTS (pass --here to sandbox it anyway)"
fi

# sanity: never share $HOME or ~/projects. The homes, the nix store and the presets are handed to
# bwrap or read from the host side, so nothing an agent can write may reach their top level.
[[ $ROOT != "$HOME" && $ROOT != / ]] || die "refusing to share $ROOT"
[[ $PROJECTS == "$ROOT" || $PROJECTS == "$ROOT"/* ]] && die "refusing to share $ROOT (contains $PROJECTS)"
for d in "$AGENT_HOME" "$HOMES" "$NIX_DIR" "$PRESETS"; do
  [[ $d == "$ROOT" || $d == "$ROOT"/* || $ROOT == "$d"/* ]] && die "refusing $ROOT (overlaps $d)"
done
for d in "$HOMES" "$NIX_DIR" "$PRESETS"; do
  [[ $d == "$AGENT_HOME" || $d == "$AGENT_HOME"/* ]] && die "refusing $d (inside the template home $AGENT_HOME)"
done

# ------------------------------------------------------------------------------- home
# One home per sandboxed directory, so an agent cannot leave something in its home for the sessions
# of another project to run. A new home is a copy of the template, made inside a sandbox of its
# own: a --shared-home session may be rewriting the template at this very moment, and a copy
# that follows a symlink swapped in underneath it must not be able to reach host files.
if ((shared_home)); then
  HOME_DIR=$AGENT_HOME
else
  id=$(printf '%s' "$ROOT" | sha256sum)
  HOME_DIR=$HOMES/${ROOT##*/}.${id:0:12}
fi
if ((!dry)) && [[ ! -d $HOME_DIR ]]; then
  info "home: new for this directory, copying the template $AGENT_HOME"
  mkdir -p -- "$HOMES"
  new=$HOME_DIR.new.$$
  mkdir -- "$new"
  copy_bash=$(need bash "copying the template home")
  copy_cp=$(need cp "copying the template home")
  bwrap --unshare-all --die-with-parent --dev /dev --tmpfs /tmp \
    --ro-bind /usr /usr --ro-bind /nix /nix --ro-bind /bin /bin --ro-bind-try /lib64 /lib64 \
    --ro-bind "$AGENT_HOME" /src --bind "$new" /dst \
    "$copy_bash" -c '
      shopt -s dotglob nullglob
      for e in /src/*; do [[ $e == /src/.cache ]] || "$0" -a --reflink=auto -- "$e" /dst/ || exit; done
    ' "$copy_cp" || {
    chmod -R u+rwx -- "$new"
    rm -rf -- "$new"
    die "could not copy the template home"
  }
  # if another sandbox of this directory was faster, its copy stays
  mv -T -- "$new" "$HOME_DIR" 2>/dev/null || { chmod -R u+rwx -- "$new"; rm -rf -- "$new"; }
fi

# ------------------------------------------------------------------------------ bwrap
DNS_ADDR=169.254.1.1 # --private-net: where pasta answers DNS on behalf of the host's resolver
args=(
  --unshare-all --die-with-parent
  --clearenv
  --dev /dev # fresh minimal /dev with its own devpts (no input devices, uinput, camera, other ttys)
  --proc /proc
  --tmpfs /tmp
  --ro-bind /usr /usr --ro-bind /etc /etc --ro-bind /nix /nix
  --ro-bind /bin /bin --ro-bind-try /lib64 /lib64
  --tmpfs /run # host /run holds every user/system socket: share nothing from it by default
  --perms 0700 --dir "/run/user/$UID"
)
((private_net)) || args+=(--share-net)
[[ -n $SANDLOCK ]] && args+=(--ro-bind "$SANDLOCK" /run/sandlock)
case $nix in # private nix store: the host store below, additions on top; its state is in /run/nix
  ram) args+=(--overlay-src /nix/store --tmp-overlay /nix/store) ;;
  disk) args+=(--overlay-src /nix/store --overlay "$NIX_DIR/upper" "$NIX_DIR/work" /nix/store --bind "$NIX_DIR/var" /run/nix) ;;
esac
[[ -L /run/current-system ]] && args+=(--symlink "$(readlink /run/current-system)" /run/current-system)
resolv=$(readlink -f /etc/resolv.conf || true) # NixOS: -> /run/systemd/resolve/stub-resolv.conf
if ((private_net)); then
  # the host's resolver (often on the host's loopback) is out of reach: ask pasta instead
  conf="nameserver $DNS_ADDR"$'\n'
  if [[ -r /etc/resolv.conf ]]; then
    while read -r key rest; do
      [[ $key == search || $key == domain || $key == options ]] && conf+="$key $rest"$'\n'
    done </etc/resolv.conf
  fi
  exec {resolv_fd}< <(printf '%s' "$conf")
  [[ $resolv == /run/* ]] || resolv=/etc/resolv.conf
  args+=(--perms 0444 --ro-bind-data "$resolv_fd" "$resolv")
else
  [[ $resolv == /run/* && -f $resolv ]] && args+=(--ro-bind "$resolv" "$resolv")
fi
if ((gpu)); then
  for dev in /dev/dri /dev/nvidia*; do args+=(--dev-bind "$dev" "$dev"); done
  for l in /run/opengl-driver /run/opengl-driver-32; do [[ -L $l ]] && args+=(--symlink "$(readlink "$l")" "$l"); done
fi
args+=(
  --bind "$HOME_DIR" "$HOME"
  --ro-bind-try "$HOME/.nix-profile" "$HOME/.nix-profile"
  --ro-bind-try "$HOME/.local/state/nix" "$HOME/.local/state/nix"
)
below "$ROOT" "$PROJECTS" && args+=(--tmpfs "$PROJECTS") # nothing else of ~/projects, nor the home's own projects/
args+=(--bind "$ROOT" "$ROOT" --chdir "$ROOT")

keep=(TERM COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION TERMINFO TERMINFO_DIRS
  LANG LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES LC_NUMERIC LC_TIME LC_COLLATE LC_MONETARY
  LOCALE_ARCHIVE LOCALE_ARCHIVE_2_27 TZ TZDIR EDITOR VISUAL PAGER MANPAGER LESS SHELL
  NIX_PATH NIX_PROFILES NIXPKGS_CONFIG NIX_SSL_CERT_FILE SSL_CERT_FILE XDG_CONFIG_DIRS XDG_DATA_DIRS
  INFOPATH LIBEXEC_PATH CARGO_HOME RUSTUP_HOME GOPATH NO_COLOR FORCE_COLOR)
read -r -a extra <<<"${AGENT_SANDBOX_ENV:-}"
for v in "${keep[@]}" "${extra[@]}"; do
  if [[ " ${cred_env[*]} " == *" $v "* ]]; then
    args+=(--setenv "$v" placeholder) # the secret stays outside; sandlock's proxy puts it in
  elif [[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -v $v ]]; then
    args+=(--setenv "$v" "${!v}")
  fi
done
args+=(
  --setenv PATH "$HOST_PATH"
  --setenv HOME "$HOME" --setenv USER "${USER:-$(id -un)}" --setenv LOGNAME "${USER:-$(id -un)}"
  --setenv XDG_RUNTIME_DIR "/run/user/$UID"
  --setenv AGENT_SANDBOX 1 --setenv AGENT_SANDBOX_ROOT "$ROOT"
)
# Nix under the allowlist. sandlock shows the sandbox a loopback-only network, which makes the
# nix CLI assume it is offline and turn substitution off, so turn it back on. The private store
# also builds itself what it cannot fetch (a cache the allowlist does not cover is no reason
# to fail), builds without nix's sandbox (it needs namespaces sandlock denies) and leaves
# deduplication alone (it hard-links into the host's .links, which the overlay cannot do).
nixconf=''
case $nix in
  daemon) nixconf='substitute = true' ;;
  ram | disk)
    nixconf=$'substitute = true\nfallback = true\nsandbox = false\nauto-optimise-store = false'
    args+=(--setenv NIX_REMOTE 'local?state=/run/nix/state&log=/run/nix/log')
    ;;
esac
if [[ -n $nixconf ]]; then
  for v in "${extra[@]}"; do [[ $v == NIX_CONFIG && -v NIX_CONFIG ]] && nixconf+=$'\n'$NIX_CONFIG; done
  args+=(--setenv NIX_CONFIG "$nixconf")
fi
# HTTP rules: sandlock's proxy decrypts HTTPS with a CA of its own. It splices that CA into the
# bundles named with --http-inject-ca whenever they are opened, so point the usual variables at
# the system bundle. Node and Bun only take additional CAs from a file of their own.
ca_bundles=()
if ((http)); then
  for f in /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-bundle.crt /etc/pki/tls/certs/ca-bundle.crt; do
    [[ -f $f ]] && ca_bundles+=("$f")
  done
  ((${#ca_bundles[@]})) || die "HTTP rules need the system CA bundle, and there is none in /etc/ssl/certs or /etc/pki/tls/certs"
  for v in SSL_CERT_FILE NIX_SSL_CERT_FILE CURL_CA_BUNDLE REQUESTS_CA_BUNDLE; do args+=(--setenv "$v" "${ca_bundles[0]}"); done
  args+=(--setenv NODE_EXTRA_CA_CERTS /run/sandlock-ca.pem)
fi

# Landlock (ABI >= 6): block connect() to abstract unix sockets created outside the sandbox.
# --share-net keeps the host's abstract socket namespace (X11 at @/tmp/.X11-unix/X0, ...).
# Python runs isolated (-I) so nothing from the agent-writable cwd is imported.
LANDLOCK_SHIM='
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
abi = libc.syscall(444, None, ctypes.c_size_t(0), ctypes.c_uint32(1))
if abi >= 6:
    attr = (ctypes.c_uint64 * 3)(0, 0, 1)  # fs, net, scoped = LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET
    fd = libc.syscall(444, attr, ctypes.c_size_t(24), ctypes.c_uint32(0))
    if fd < 0 or libc.prctl(38, 1, 0, 0, 0) != 0 or libc.syscall(446, ctypes.c_int(fd), ctypes.c_uint32(0)) != 0:
        sys.exit("sandbox: landlock setup failed: " + os.strerror(ctypes.get_errno()))
    os.close(fd)
else:
    print("sandbox: warning: landlock ABI < 6, abstract unix sockets (X11) stay reachable", file=sys.stderr)
os.environ.pop("PYTHONNOUSERSITE", None)  # set by the nix python wrapper, not by the user
try:
    os.execvp(sys.argv[1], sys.argv[1:])
except OSError as e:
    print(f"sandbox: {sys.argv[1]}: {e.strerror}", file=sys.stderr)
    os._exit(127)
'
# Private nix store (--nix-store ram|disk): give it a database before the command starts. This
# runs inside sandlock, because with --nix-store disk the previous database is agent-written.
# A snapshot of the host's database makes every path of the host store valid here. Paths the
# sandbox added in earlier sessions are carried over if they are still on disk and everything
# they reference still exists; the rest is left for nix to replace when it needs it. Its leading
# arguments (up to --) are lock files to hide, see below.
NIX_SEED='
import os, shutil, sqlite3, sys
sep = sys.argv.index("--")
locks, command = sys.argv[1:sep], sys.argv[sep + 1:]
host, state = "/nix/var/nix/db", "/run/nix/state"
db = state + "/db/db.sqlite"
new = db + ".new"
def drop(*files):
    for f in files:
        if os.path.lexists(f):
            os.unlink(f)
os.makedirs(state + "/db", exist_ok=True)
drop(new, new + "-wal", new + "-shm")
src = sqlite3.connect("file:" + host + "/db.sqlite?mode=ro", uri=True)
dst = sqlite3.connect(new)
src.backup(dst)
src.close()
if os.path.lexists(db):
    try:
        dst.execute("attach database ? as old", (db,))
        cols = ", ".join(r[1] for r in dst.execute("pragma main.table_info(ValidPaths)") if r[1] != "id")
        dst.execute("create temp table keep (id integer primary key, path text)")
        dst.execute("insert into keep select id, path from old.ValidPaths where path not in (select path from main.ValidPaths)")
        gone = [(i,) for i, p in dst.execute("select id, path from keep").fetchall() if not os.path.lexists(p)]
        dst.executemany("delete from keep where id = ?", gone)
        while dst.execute("""delete from keep where id in (
                select r.referrer from old.Refs r join old.ValidPaths t on t.id = r.reference
                where r.referrer in (select id from keep) and t.id not in (select id from keep)
                  and t.path not in (select path from main.ValidPaths))""").rowcount:
            pass
        dst.execute("insert into main.ValidPaths (%s) select %s from old.ValidPaths where id in (select id from keep)" % (cols, cols))
        dst.execute("""insert or ignore into main.Refs (referrer, reference)
                select a.id, b.id from old.Refs r
                join old.ValidPaths oa on oa.id = r.referrer join main.ValidPaths a on a.path = oa.path
                join old.ValidPaths ob on ob.id = r.reference join main.ValidPaths b on b.path = ob.path
                where r.referrer in (select id from keep)""")
        dst.execute("""insert or ignore into main.DerivationOutputs (drv, id, path)
                select a.id, d.id, d.path from old.DerivationOutputs d
                join old.ValidPaths oa on oa.id = d.drv join main.ValidPaths a on a.path = oa.path
                where d.drv in (select id from keep)""")
        dst.commit()
    except sqlite3.Error as e:
        dst.rollback()
        print(f"sandbox: nix store: earlier additions are not carried over ({e})", file=sys.stderr)
dst.close()
drop(db + "-wal", db + "-shm")
os.replace(new, db)
for f in os.listdir(host):
    if f.endswith("schema"):
        shutil.copyfile(host + "/" + f, state + "/db/" + f)
drop(*("/nix/store/" + name for name in locks))
os.environ.pop("PYTHONNOUSERSITE", None)  # set by the nix python wrapper, not by the user
try:
    os.execvp(command[0], command)
except OSError as e:
    print(f"sandbox: {command[0]}: {e.strerror}", file=sys.stderr)
    os._exit(127)
'
# --private-net: attach pasta to the sandbox once bwrap has created its namespaces. pasta has to
# enter the user namespace that owns the network namespace; bwrap nests two, and the sandbox's
# processes live in the inner one, so ask the kernel for the owner (NS_GET_USERNS).
PASTA_JOIN='
import fcntl, os, subprocess, sys
child, pasta = sys.argv[1], sys.argv[2:]
net = os.open("/proc/%s/ns/net" % child, os.O_RDONLY)
owner = fcntl.ioctl(net, 0xB701)
sys.exit(subprocess.call(pasta + ["--userns", "/proc/%d/fd/%d" % (os.getpid(), owner), "--netns", "/proc/%s/ns/net" % child]))
'
# --net-learn: read pasta's packet capture from a pipe as it is written and note where the
# sandbox connects to. Names come from the TLS server name of a connection, else from the DNS
# answer that produced the address, else the address stays. This runs outside the sandbox on
# data the sandbox controls: it only ever emits "--net-allow HOST:PORTS" lines with checked
# characters. Arguments: capture pipe, preset file, address pasta answers DNS on.
LEARN='
import datetime, ipaddress, os, re, struct, sys
fifo, preset, dns_addr = sys.argv[1], sys.argv[2], ipaddress.ip_address(sys.argv[3])
names, sni, tcp, udp, udp_seen, opening = {}, {}, set(), set(), set(), set()

def name_at(b, off):
    labels, after = [], None
    for _ in range(128):
        n = b[off]
        if n & 0xC0 == 0xC0:
            after = after or off + 2
            off = (n & 0x3F) << 8 | b[off + 1]
        elif n:
            labels.append(b[off + 1:off + 1 + n].decode("ascii", "replace"))
            off += 1 + n
        else:
            return ".".join(labels).lower(), after or off + 1
    raise ValueError("name")

def dns_answer(b):
    flags, questions, answers = struct.unpack("!HHH", b[2:8])
    if not flags & 0x8000 or not questions:
        return
    asked, off = name_at(b, 12)
    off += 4
    for _ in range(questions - 1):
        off = name_at(b, off)[1] + 4
    for _ in range(answers):
        off = name_at(b, off)[1]
        kind, size = struct.unpack("!H6xH", b[off:off + 10])
        off += 10
        if kind in (1, 28):
            names[ipaddress.ip_address(b[off:off + size])] = asked
        off += size

def server_name(p):
    if p[0] != 0x16 or p[5] != 0x01:
        return None
    off = 43
    off += 1 + p[off]
    off += 2 + int.from_bytes(p[off:off + 2], "big")
    off += 1 + p[off]
    end = off + 2 + int.from_bytes(p[off:off + 2], "big")
    off += 2
    while off + 4 <= end:
        kind, size = struct.unpack("!HH", p[off:off + 4])
        off += 4
        if kind == 0:
            return p[off + 5:off + 5 + int.from_bytes(p[off + 3:off + 5], "big")].decode("ascii", "replace").lower()
        off += size

def frame(f):
    kind, ip = f[12:14], f[14:]
    if kind == b"\x08\x00":
        if int.from_bytes(ip[6:8], "big") & 0x1FFF:
            return
        proto, src, dst, l4 = ip[9], ip[12:16], ip[16:20], ip[(ip[0] & 15) * 4:int.from_bytes(ip[2:4], "big")]
    elif kind == b"\x86\xdd":
        proto, src, dst, l4 = ip[6], ip[8:24], ip[24:40], ip[40:]
    else:
        return
    src, dst = ipaddress.ip_address(src), ipaddress.ip_address(dst)
    sport, dport = struct.unpack("!HH", l4[:4])
    flow = (src, sport, dst, dport)
    if proto == 6:
        payload = l4[(l4[12] >> 4) * 4:]
        if l4[13] & 0x12 == 0x02:
            tcp.add((dst, dport))
            if len(opening) < 10000:
                opening.add(flow)
        elif payload and flow in opening:
            opening.discard(flow)
            name = server_name(payload)
            if name:
                sni.setdefault((dst, dport), set()).add(name)
    elif proto == 17:
        if src == dns_addr and sport == 53:
            dns_answer(l4[8:])
        elif dst != dns_addr and (dst, dport, src, sport) not in udp_seen:
            udp.add((dst, dport))
            if len(udp_seen) < 100000:
                udp_seen.add(flow)

with open(fifo, "rb") as f:
    order = "<" if f.read(24)[:4] in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
    while True:
        head = f.read(16)
        if len(head) < 16:
            break
        data = f.read(struct.unpack(order + "4I", head)[2])
        try:
            frame(data)
        except (IndexError, ValueError, struct.error):
            pass

def hosts(ip, port):
    good = [n for n in sni.get((ip, port)) or [names.get(ip, "")]
            if re.fullmatch("[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?", n) and re.search("[a-z]", n)]
    return good or ["[%s]" % ip if ip.version == 6 else str(ip)]

ports = {}
for proto, seen in (("tcp", tcp), ("udp", udp)):
    for ip, port in seen:
        if not (ip.is_multicast or ip.is_loopback or ip.is_unspecified or ip == ipaddress.ip_address("255.255.255.255")):
            for h in hosts(ip, port):
                ports.setdefault(h, {}).setdefault(port, set()).add(proto)
lines = []
for h in sorted(ports):
    both = sorted(p for p, protos in ports[h].items() if "tcp" in protos)
    only_udp = sorted(p for p, protos in ports[h].items() if "tcp" not in protos)
    if both:
        lines.append("--net-allow %s:%s" % (h, ",".join(map(str, both))))
    if only_udp:
        lines.append("--net-allow udp://%s:%s" % (h, ",".join(map(str, only_udp))))
try:
    known = set(open(preset).read().splitlines())
except OSError:
    known = set()
new = [line for line in lines if line not in known]
if new:
    os.makedirs(os.path.dirname(preset), exist_ok=True)
    with open(preset, "a") as out:
        out.write("# learned %s\n%s\n" % (datetime.date.today(), "\n".join(new)))
print("sandbox: destinations contacted: %d; added to %s: %d" % (len(lines), preset, len(new)), file=sys.stderr)
for line in new:
    print("  " + line, file=sys.stderr)
'
# herdr picks a pane's agent from its host-visible processes. pi's claude-bridge provider
# runs a `claude` child, which herdr would pick instead of pi. herdr reads this hint from
# bwrap's environment; --clearenv keeps it out of the sandbox.
case $1 in pi | */pi) export HERDR_AGENT=pi ;; esac

# sandlock reports every request it attaches a credential to on stderr, which would scribble over
# a terminal program. On a terminal, filter those reports out of bwrap's stderr and give the
# command the terminal itself as stderr again.
quiet_auth=0
((${#http_auth[@]})) && [[ -t 2 ]] && quiet_auth=1

cmd=("$@")
if [[ -n $SANDLOCK ]]; then
  # Allowlist: sandlock runs the command under a seccomp supervisor that lets connect() and
  # sendto() reach only the allowed endpoints and serves the resolved hostnames as /etc/hosts.
  # It applies the same abstract-socket Landlock scope itself, so no shim here.
  # The filesystem stays bwrap's job: Landlock gets read on everything bwrap exposes and write
  # on what bwrap leaves writable. Keeping /nix/var read-only for Landlock is deliberate:
  # sandlock only connects to unix sockets below a write grant, which puts the nix daemon (it
  # would fetch anything on the agent's behalf) out of reach unless its socket is granted.
  cmd=(/run/sandlock run -r /)
  for p in "$HOME" "$ROOT" /tmp /dev /run /proc; do cmd+=(-w "$p"); done
  # A terminal or file inherited on stdio lies outside those paths. Grant the inode itself so
  # reopening it (echo >/dev/stderr, tee /dev/stdout) keeps working; pipes need no grant.
  stdio=(/dev/stdin /dev/stdout /dev/stderr)
  for fd in 0 1 2; do
    ((fd == 2 && quiet_auth)) && continue # sandlock's stderr is the filter's pipe then
    [[ -c /dev/fd/$fd || -f /dev/fd/$fd ]] && cmd+=(-w "${stdio[fd]}")
  done
  case $nix in
    daemon) cmd+=(-w /nix/var/nix/daemon-socket/socket) ;;
    ram | disk) cmd+=(-w /nix/store) ;;
  esac
  for s in "${net_allow[@]}"; do cmd+=("--net-allow=$s"); done
  if ((private_net)); then
    # loopback is the sandbox's own here: nothing to protect, so talking and listening are free
    cmd+=(--net-allow=127.0.0.0/8 --net-allow=::1)
    ((${#net_bind[@]})) || net_bind=('*')
  fi
  for s in "${net_bind[@]}"; do cmd+=("--net-allow-bind=$s"); done
  if ((http)); then
    for f in "${ca_bundles[@]}"; do cmd+=("--http-inject-ca=$f"); done
    cmd+=(--http-ca-out=/run/sandlock-ca.pem)
    # With the proxy on, every request to ports 80 and 443 needs a rule. Keep --net-allow hosts
    # open, unless --http-allow rules of their own say what is allowed there.
    ruled=' '
    for s in "${http_allow[@]}"; do s=${s#* } ruled+="${s%%/*} "; done
    for s in "${net_allow[@]}"; do
      [[ $s == udp://* || $s == icmp://* ]] && continue
      s=${s#tcp://} p=''
      [[ $s == *:* ]] && p=,${s#*:},
      [[ -z $p || $p == *,80,* || $p == *,443,* || $p == ',*,' ]] || continue
      s=${s%%:*}
      [[ $s =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $s == *[A-Za-z]* && $ruled != *" $s "* ]] && cmd+=("--http-allow=* $s/*")
    done
    for s in "${http_allow[@]}"; do cmd+=("--http-allow=$s"); done
    for s in "${http_deny[@]}"; do cmd+=("--http-deny=$s"); done
    for s in "${http_auth[@]}"; do cmd+=("--http-auth=$s"); done
  fi
  for i in "${!cred_names[@]}"; do
    # sandlock's supervisor reads the secret from a descriptor; the command does not inherit it
    fd=N
    if ((!dry)); then
      case ${cred_sources[i]} in
        env:*) v=${cred_sources[i]#env:}; exec {fd}< <(printf '%s' "${!v}") ;;
        file:*) exec {fd}<"${cred_sources[i]#file:}" ;;
      esac
    fi
    cmd+=("--credential=${cred_names[i]}=fd:$fd")
  done
  cmd+=(--)
  ((quiet_auth)) && cmd+=(/bin/sh -c 'if (: >/dev/tty) 2>/dev/null; then exec 2>/dev/tty; fi; exec "$@"' sh)
  if [[ $nix == ram || $nix == disk ]]; then
    # Builds that failed on the host leave their lock files in the store. They are root-owned, so
    # nix in the sandbox could never take them: have the seed step remove them from the overlay.
    locks=()
    for f in /nix/store/*.lock; do [[ -r $f ]] || locks+=("${f##*/}"); done
    cmd+=("$PYTHON" -I -c "$NIX_SEED" "${locks[@]}" --)
  fi
  cmd+=("$@")
elif py=$(command -v python3); then
  cmd=("$(realpath "$py")" -I -c "$LANDLOCK_SHIM" "$@")
else
  info "warning: python3 not found, skipping landlock (abstract unix sockets stay reachable)"
fi

pasta=(--config-net -q -u none -T none -U none --no-map-gw --dns-forward "$DNS_ADDR")
# forwards: from the host's loopback to the sandbox's loopback, where servers usually listen
for f in "${forwards[@]}"; do pasta+=(-t "127.0.0.1/$f"); done
if ((${#forwards[@]})); then pasta+=(--host-lo-to-ns-lo); else pasta+=(-t none); fi

if ((dry)); then
  printf '%q ' bwrap "${args[@]}" -- "${cmd[@]}"; printf '\n'
  ((private_net)) && { printf '# and, attached to its network namespace: '; printf '%q ' pasta "${pasta[@]}"; printf '\n'; }
  exit 0
fi
info "sharing $ROOT"
((shared_home)) && info "home: the template $AGENT_HOME itself (read-write)"
if [[ -n $SANDLOCK ]]; then
  what=("${net_allow[@]}")
  ((http)) && what+=("HTTP rules (${#http_allow[@]} allow, ${#http_deny[@]} deny, ${#http_auth[@]} with a credential)")
  info "network: only ${what[*]}"
elif [[ -n $learn ]]; then
  info "network: open and private; recording destinations for preset $learn"
elif ((private_net)); then
  info "network: open, in a namespace of its own"
fi
case $nix in
  ram) info "nix: private store in memory" ;;
  daemon) info "nix: host daemon (not covered by the allowlist)" ;;
  none) info "nix: unavailable" ;;
  disk)
    info "nix: private store in $NIX_DIR"
    mkdir -p -- "$NIX_DIR"/{upper,work,var}
    touch -- "$NIX_DIR/lock"
    # One overlay per upper layer. bwrap inherits the descriptor, so the lock lasts as long as
    # the sandbox.
    exec {nixlock}<"$NIX_DIR/lock"
    flock -n "$nixlock" || die "nix store $NIX_DIR is in use by another sandbox (try --nix-store ram)"
    # Upper entries shadow the host store, and everything started in the sandbox is loaded
    # through this overlay. So whatever the host store has by now wins: drop the sandbox's copy.
    (
      shopt -s dotglob
      for e in "$NIX_DIR"/upper/*; do
        [[ -e /nix/store/${e##*/} || -L /nix/store/${e##*/} ]] || continue
        [[ -L $e ]] || chmod -R u+w -- "$e"
        rm -rf -- "$e"
      done
    )
    ;;
esac

# ----------------------------------------------------------------------------- launch
join_net() { # runs beside bwrap: wait for its namespaces, attach pasta, then let the command start
  local line child='' log
  while [[ -z $child ]]; do
    if read -r -t 1 -u "$info_fd" line; then
      [[ $line == gone ]] && return 1
      [[ $line =~ \"child-pid\":\ *([0-9]+) ]] && child=${BASH_REMATCH[1]}
    else
      kill -0 "$1" 2>/dev/null || return 1 # bwrap did not get that far
    fi
  done
  log=$(mktemp)
  if "$PYTHON" -I -c "$PASTA_JOIN" "$child" "$PASTA" "${pasta[@]}" >"$log" 2>&1; then
    rm -f -- "$log" # pasta keeps it open: whatever it says later goes nowhere
    printf x >&"$block_fd"
  else
    info "pasta could not set up the network: $(<"$log")"
    rm -f -- "$log"
    kill -KILL "$child" 2>/dev/null
    return 1
  fi
}

reader='' helper=''
if ((private_net)); then
  if [[ -n $learn ]]; then
    learn_dir=$(mktemp -d)
    mkfifo -- "$learn_dir/pcap"
    pasta+=(--pcap "$learn_dir/pcap")
    "$PYTHON" -I -c "$LEARN" "$learn_dir/pcap" "$PRESETS/$learn" "$DNS_ADDR" &
    reader=$!
  fi
  # two anonymous pipes: bwrap reports its child on one and waits for a byte on the other
  exec {info_fd}<> <(:) {block_fd}<> <(:)
  args=(--info-fd "$info_fd" --block-fd "$block_fd" "${args[@]}")
  join_net $$ &
  helper=$!
fi

if ((quiet_auth)) || [[ -n $learn ]]; then
  # something is left to do when the sandbox ends, so stay around instead of exec'ing bwrap
  trap : INT
  rc=0
  if ((quiet_auth)); then
    bwrap "${args[@]}" -- "${cmd[@]}" 2> >(exec sed -u '/^sandlock: \(injected\|kept caller-supplied\) credential /d' >&2) || rc=$?
    wait $! 2>/dev/null || :
  else
    bwrap "${args[@]}" -- "${cmd[@]}" || rc=$?
  fi
  [[ -z $helper ]] || echo gone >&"$info_fd" # in case bwrap failed before join_net heard from it
  if [[ -n $reader ]]; then
    # pasta ends with the sandbox and closes the capture, which lets the reader report
    if wait "$helper"; then wait "$reader" || :; else kill "$reader" 2>/dev/null || :; fi
    rm -rf -- "$learn_dir"
  fi
  exit "$rc"
fi
exec bwrap "${args[@]}" -- "${cmd[@]}"
