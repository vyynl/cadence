#!/usr/bin/env bash
# Register a directory with the Cadence daemon and print its server page.
#
# The one-command bootstrap for the container flow in DAEMON.md: start (or
# reuse) the daemon container, wait for its socket, register the directory,
# report whether sync can reach the server, and print the project URL as a
# clickable link.
#
#   scripts/cadence-up.sh                      # current directory
#   scripts/cadence-up.sh ~/code/my-project    # explicit directory
#   scripts/cadence-up.sh ~/code/api --slug api --name "API"
#
# Options:
#   --slug SLUG            project slug (default: derived from the directory)
#   --name NAME            display name (default: the directory name)
#   --host                 use a host release instead of a container
#   --container            force the container flow (the default)
#   --require-connection   exit non-zero when sync cannot reach the server
#
# Environment:
#   CAD_DAEMON_IMAGE       container image (ghcr.io/vyynl/cadence-daemon:latest)
#   CAD_DAEMON_NAME        container name (cadence-daemon)
#   CAD_DAEMON_BIN         release binary for --host
#   CAD_NETWORK            docker network for a new container (none)
#   CAD_STATE_DIR          state directory (~/.local/state/cadence)
#   CAD_SERVER_URL, CAD_AUTH_TOKEN, CAD_SYNC_CA_FILE, CAD_SYNC_VERIFY_TLS
#                          forwarded when set, otherwise read from daemon.env
#
# Exit status: 0 when the project is registered locally. The server connection
# is reported on its own line and only fails the run with
# --require-connection, because a registered project still commits and serves
# the DAG offline.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# Colours only for a terminal, and never when the caller asked for plain text.
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-}" != "dumb" ]]; then
  c_reset=$'\033[0m'
  c_bold=$'\033[1m'
  c_dim=$'\033[2m'
  c_red=$'\033[31m'
  c_green=$'\033[32m'
  c_yellow=$'\033[33m'
  c_blue=$'\033[36m'
else
  c_reset='' c_bold='' c_dim='' c_red='' c_green='' c_yellow='' c_blue=''
fi

step() { printf '%s%s%s\n' "$c_bold" "$*" "$c_reset"; }
ok() { printf '  %sok%s     %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '  %swarn%s   %s\n' "$c_yellow" "$c_reset" "$*"; }
info() { printf '  %s%s%s\n' "$c_dim" "$*" "$c_reset"; }
fail() {
  printf '%serror%s   %s\n' "$c_red" "$c_reset" "$*" >&2
  exit 1
}

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

project=''
slug=''
name=''
mode='container'
require_connection=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)
      [[ $# -ge 2 ]] || fail '--slug needs a value'
      slug="$2"
      shift 2
      ;;
    --name)
      [[ $# -ge 2 ]] || fail '--name needs a value'
      name="$2"
      shift 2
      ;;
    --host)
      mode='host'
      shift
      ;;
    --container)
      mode='container'
      shift
      ;;
    --require-connection)
      require_connection=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --*)
      fail "unknown option: $1 (try --help)"
      ;;
    *)
      [[ -z "$project" ]] || fail "unexpected argument: $1"
      project="$1"
      shift
      ;;
  esac
done

project="${project:-$PWD}"
[[ -d "$project" ]] || fail "not a directory: $project"
project="$(cd "$project" && pwd -P)"
[[ "$project" != '/' ]] || fail 'refusing to register the filesystem root'

base="$(basename "$project")"
[[ -n "$name" ]] || name="$base"

if [[ -z "$slug" ]]; then
  slug="$(
    printf '%s' "$base" |
      tr '[:upper:]' '[:lower:]' |
      sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//'
  )"
fi
[[ -n "$slug" ]] || fail "cannot derive a slug from '$base'; pass --slug"

state="${CAD_STATE_DIR:-$HOME/.local/state/cadence}"
conf="$state/daemon.env"
image="${CAD_DAEMON_IMAGE:-ghcr.io/vyynl/cadence-daemon:latest}"
cname="${CAD_DAEMON_NAME:-cadence-daemon}"

mkdir -p "$state"

# Read a setting from the environment first, then from daemon.env. Parsed with
# sed rather than sourced: setup writes plain KEY=value lines, and sourcing a
# file is not worth the shell-evaluation risk.
env_value() {
  local key="$1" value="${!1:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi
  [[ -f "$conf" ]] || return 0
  sed -n "s/^${key}=//p" "$conf" | head -n 1
}

server_url="$(env_value CAD_SERVER_URL)"
ca_file="$(env_value CAD_SYNC_CA_FILE)"
verify_tls="$(env_value CAD_SYNC_VERIFY_TLS)"

step 'Cadence daemon'
printf '  %-8s %s\n' 'state' "$state"
printf '  %-8s %s (slug: %s)\n' 'project' "$project" "$slug"

# -- configure ---------------------------------------------------------------

if [[ ! -f "$conf" ]] && [[ -z "$(env_value CAD_AUTH_TOKEN)" ]]; then
  if [[ "$mode" == 'host' ]]; then
    fail "no $conf and no CAD_AUTH_TOKEN; export CAD_SERVER_URL and CAD_AUTH_TOKEN, or configure the daemon first (DAEMON.md)"
  fi

  if [[ ! -t 0 ]]; then
    fail "no $conf and no CAD_AUTH_TOKEN; run this from a terminal so setup can prompt, or configure the daemon first (DAEMON.md)"
  fi

  info 'no daemon.env yet: setup asks for the server URL and an API token'
  # Same network as the container that follows, so setup can verify the
  # connection instead of only recording the values.
  setup_args=(run --rm -it --user "$(id -u):$(id -g)")
  [[ -n "${CAD_NETWORK:-}" ]] && setup_args+=(--network "$CAD_NETWORK")
  setup_args+=(-v "$state:$state" -e "CAD_STATE_DIR=$state" "$image" setup)
  docker "${setup_args[@]}"
fi

# -- start the daemon --------------------------------------------------------

if [[ "$mode" == 'container' ]]; then
  if docker inspect "$cname" >/dev/null 2>&1; then
    if ! docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$cname" |
      grep -Fxq -- "$project"; then
      fail "container $cname does not mount $project; recreate it with -v $project:$project (DAEMON.md)"
    fi

    if [[ "$(docker inspect -f '{{.State.Running}}' "$cname")" == 'true' ]]; then
      ok "daemon container $cname is running"
    else
      docker start "$cname" >/dev/null
      ok "started container $cname"
    fi
  else
    args=(run -d --name "$cname" --restart unless-stopped --user "$(id -u):$(id -g)")
    [[ -n "${CAD_NETWORK:-}" ]] && args+=(--network "$CAD_NETWORK")
    args+=(-v "$state:$state" -e "CAD_STATE_DIR=$state" -v "$project:$project")

    # A CA bundle has to be readable inside the container at the same path.
    if [[ -n "$ca_file" ]]; then
      [[ -f "$ca_file" ]] || fail "CAD_SYNC_CA_FILE=$ca_file is not a file"
      args+=(-v "$ca_file:$ca_file:ro" -e "CAD_SYNC_CA_FILE=$ca_file")
    fi
    [[ -n "$verify_tls" ]] && args+=(-e "CAD_SYNC_VERIFY_TLS=$verify_tls")

    docker "${args[@]}" "$image" >/dev/null
    ok "started $image"
  fi
else
  bin="${CAD_DAEMON_BIN:-$repo/_build/prod/rel/cadence_daemon/bin/cadence_daemon}"
  [[ -x "$bin" ]] || fail "--host needs a release binary; set CAD_DAEMON_BIN ($bin is not executable)"

  if [[ -S "$state/daemon.sock" ]]; then
    ok "using the daemon at $state/daemon.sock"
  else
    fail "no daemon socket at $state/daemon.sock; start it with '$bin start'"
  fi
fi

# Evaluated inside the daemon's environment so paths and names need no shell
# quoting: the values arrive as CAD_UP_* variables. `docker exec` does not
# inherit what the entrypoint sourced from daemon.env, so the file is re-read
# into the exec: that keeps the token out of argv and gives the eval the same
# server configuration the daemon is running with.
eval_daemon() {
  if [[ "$mode" == 'container' ]]; then
    local -a env_args=(-e CAD_UP_NAME="$name" -e CAD_UP_SLUG="$slug" -e CAD_UP_DIR="$project")
    if [[ -f "$conf" ]]; then
      env_args+=(--env-file "$conf")
    else
      [[ -n "${CAD_SERVER_URL:-}" ]] && env_args+=(-e "CAD_SERVER_URL=$CAD_SERVER_URL")
      [[ -n "${CAD_AUTH_TOKEN:-}" ]] && env_args+=(-e "CAD_AUTH_TOKEN=$CAD_AUTH_TOKEN")
    fi

    docker exec "${env_args[@]}" "$cname" bin/cadence_daemon eval "$1"
  else
    env CAD_STATE_DIR="$state" \
      CAD_UP_NAME="$name" CAD_UP_SLUG="$slug" CAD_UP_DIR="$project" \
      "$bin" eval "$1"
  fi
}

# Runs against any daemon that already has `Release.register/3` and
# `Client.expect!/4` (1.1.0 and later), so a newer script still bootstraps an
# older image. Project state arrives as CAD_UP_* variables, which keeps the
# quoting out of the shell.
register_expression='dir = Path.expand(System.fetch_env!("CAD_UP_DIR"))
projects = Cadence.Daemon.Client.expect!("GET", "/projects")["projects"]

case Enum.find(projects, &(&1["work_dir"] == dir)) do
  nil ->
    Cadence.Daemon.Release.register(
      System.fetch_env!("CAD_UP_NAME"),
      System.fetch_env!("CAD_UP_SLUG"),
      dir
    )

  project ->
    IO.puts("already registered: #{project["slug"]}")
end'

# -- register (retrying the boot window) -------------------------------------

deadline=$((SECONDS + 30))
printf '  %swaiting for the daemon socket%s ' "$c_dim" "$c_reset"

while :; do
  if output="$(eval_daemon "$register_expression" 2>&1)"; then
    printf '\n'
    break
  fi

  case "$output" in
    *'daemon unreachable at'* | *':econnrefused'* | *':enoent'*)
      if ((SECONDS >= deadline)); then
        printf '\n'
        fail "the daemon did not accept a connection within 30 s:
$output"
      fi
      printf '.'
      sleep 1
      ;;
    *)
      printf '\n'
      fail "registration failed:
$output"
      ;;
  esac
done

ok "project registered at $project"

# -- server connection -------------------------------------------------------

connection=0
# One implementation, shared with the image's `setup` (Release.check_connection).
connection_expression='IO.inspect(Cadence.Daemon.Release.check_connection())'

connection_output="$(eval_daemon "$connection_expression" 2>&1 || true)"

# One line, without the TLS notices the handshake logs: enough to recognise the
# reason, short enough for a status line.
summary="$(
  printf '%s\n' "$connection_output" |
    grep -v 'TLS :client' |
    tr -s '[:space:]' ' ' |
    sed -e 's/^ //' -e 's/ $//' |
    cut -c1-160
)"

case "$connection_output" in
  *':ok'*)
    ok "server authenticated (${server_url:-CAD_SERVER_URL})"
    connection=1
    ;;
  *':not_configured'*)
    warn 'no server configured: commits stay local'
    info "fill CAD_SERVER_URL and CAD_AUTH_TOKEN in $conf to enable sync"
    ;;
  *'{:error, :unauthorized}'*)
    warn 'the server rejected the token (401)'
    info 'mint a new token at /auth/tokens/new and re-run the daemon setup'
    ;;
  *'{:error, :certificate}'*)
    warn 'sync cannot reach the server: its certificate is not trusted'
    info 'set CAD_SYNC_CA_FILE to the issuing CA (DAEMON.md#configure)'
    info 'TROUBLESHOOTING.md#daemon-logs-unknown-ca-or-gets-a-403'
    ;;
  *'{:error, {:http, 403}'*)
    warn 'sync cannot reach the server: HTTP 403'
    info 'a firewall or proxy is blocking the host, which no TLS setting changes'
    info 'TROUBLESHOOTING.md#daemon-logs-unknown-ca-or-gets-a-403'
    ;;
  *'{:error, :unreachable}'*)
    warn 'sync cannot reach the server: no connection'
    info 'a local server is reachable by service name, not localhost (CAD_NETWORK)'
    info 'TROUBLESHOOTING.md#daemon-cannot-reach-the-server'
    ;;
  *)
    warn 'sync cannot reach the server'
    info "$summary"
    info 'TROUBLESHOOTING.md#daemon-cannot-reach-the-server'
    ;;
esac

# -- the page ----------------------------------------------------------------

printf '\n'
if [[ -n "$server_url" ]]; then
  url="${server_url%/}/p/${slug}"
  if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    # OSC 8 hyperlink. The URL is the link text too, so a terminal without
    # support still shows something usable.
    printf '  %-8s \033]8;;%s\033\\%s%s%s\033]8;;\033\\\n' 'page' "$url" "$c_blue" "$url" "$c_reset"
  else
    printf '  %-8s %s\n' 'page' "$url"
  fi
else
  info 'set CAD_SERVER_URL in daemon.env to get a project URL'
fi

if ((require_connection == 1 && connection == 0)); then
  fail 'the project is registered but the server connection failed (--require-connection)'
fi
