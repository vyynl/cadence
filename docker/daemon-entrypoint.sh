#!/bin/sh
# Entrypoint for the Cadence daemon image.
#
#   docker run … <image> setup     interactive config: server URL + API token
#   docker run … <image>           load that config, migrate, start the daemon
#   docker run … <image> <cmd…>    run something else (bin/cadence_daemon eval …)
#
# The config lands in the state volume, so it survives restarts and upgrades and
# the token never has to appear in `docker run -e` or in shell history.
set -eu

STATE="${CAD_STATE_DIR:-/data/state}"
CONF="$STATE/daemon.env"
RELEASE="$(dirname "$0")/cadence_daemon"

mask() {
  # Print the config with the token redacted.
  sed -e 's/^\(CAD_AUTH_TOKEN=\).*/\1<hidden>/' "$CONF"
}

setup() {
  if ! mkdir -p "$STATE" 2>/dev/null || [ ! -w "$STATE" ]; then
    echo "error: $STATE is not writable by uid $(id -u)." >&2
    echo "Create it on the host and run with --user $(id -u):$(id -g)." >&2
    exit 1
  fi

  if [ -f "$CONF" ]; then
    echo "Existing configuration in $CONF:"
    mask
    printf '\nReplace it? [y/N] '
    read -r answer
    case "$answer" in
      y | Y) ;;
      *) echo "keeping the existing configuration"; exit 0 ;;
    esac
  fi

  printf 'Server URL (for example https://cadence.example.com): '
  read -r server_url
  printf 'API token (mint it at /auth/tokens/new on the server): '

  # Hide the token while it is typed. `stty` only works on a terminal, so a
  # piped setup (for example in a script) keeps the value on stdin.
  hide=0
  if [ -t 0 ] && stty -echo 2>/dev/null; then
    hide=1
    trap 'stty echo 2>/dev/null || true' 0
  fi

  read -r token

  if [ "$hide" = 1 ]; then
    stty echo 2>/dev/null || true
    trap - 0
    printf '\n'
  fi

  if [ -z "$server_url" ] || [ -z "$token" ]; then
    echo "both values are required; nothing written" >&2
    exit 1
  fi

  umask 077
  printf 'CAD_SERVER_URL=%s\nCAD_AUTH_TOKEN=%s\n' "$server_url" "$token" >"$CONF"
  chmod 600 "$CONF"

  # Create the database now so the first start is quick and quiet.
  "$RELEASE" eval "Cadence.Daemon.Release.migrate()" >/dev/null
  echo "Wrote $CONF"
  echo "Start the daemon with: docker run -d --name cadence-daemon … <image>"
}

start() {
  if [ -f "$CONF" ]; then
    if [ ! -r "$CONF" ]; then
      echo "error: cannot read $CONF as uid $(id -u)." >&2
      echo "Run setup and the daemon with the same --user." >&2
      exit 1
    fi

    set -a
    # shellcheck disable=SC1090
    . "$CONF"
    set +a
  else
    echo "no $CONF: running offline (no server sync). Run '<image> setup' to configure." >&2
  fi

  # Idempotent; keeps a fresh volume usable without a separate migrate step.
  "$RELEASE" eval "Cadence.Daemon.Release.migrate()" >/dev/null 2>&1 || true

  exec "$RELEASE" start
}

case "${1:-start}" in
  setup) setup ;;
  start) start ;;
  *) exec "$@" ;;
esac
