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
  mkdir -p "$STATE"

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
  read -r token

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
