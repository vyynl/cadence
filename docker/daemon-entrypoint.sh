#!/bin/sh
# Entrypoint for the Cadence daemon image.
#
#   docker run … <image> setup     interactive config: server URL, API token,
#                                  and optional AI settings
#   docker run … <image>           load that config, migrate, start the daemon
#   docker run … <image> <cmd…>    run something else (bin/cadence_daemon eval …)
#
# The config lands in the state volume, so it survives restarts and upgrades and
# the token never has to appear in `docker run -e` or in shell history.
set -eu

STATE="${CAD_STATE_DIR:-/data/state}"
CONF="$STATE/daemon.env"
RELEASE="$(dirname "$0")/cadence_daemon"

# Colour only for a terminal, and never when plain output was requested. The
# escape is built with printf so this stays POSIX sh.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  c_reset=$(printf '\033[0m')
  c_bold=$(printf '\033[1m')
  c_dim=$(printf '\033[2m')
  c_red=$(printf '\033[31m')
  c_green=$(printf '\033[32m')
  c_yellow=$(printf '\033[33m')
else
  c_reset='' c_bold='' c_dim='' c_red='' c_green='' c_yellow=''
fi

step() { printf '%s%s%s\n' "$c_bold" "$1" "$c_reset"; }
hint() { printf '  %s%s%s\n' "$c_dim" "$1" "$c_reset"; }
ok() { printf '  %sok%s     %s\n' "$c_green" "$c_reset" "$1"; }
warn() { printf '  %swarn%s   %s\n' "$c_yellow" "$c_reset" "$1" >&2; }
die() {
  printf '%serror%s   %s\n' "$c_red" "$c_reset" "$1" >&2
  exit 1
}

mask() {
  # Print the config with the secrets redacted.
  sed -e 's/^\(CAD_AUTH_TOKEN=\).*/\1<hidden>/' \
    -e 's/^\(CAD_LLM_API_KEY=\).*/\1<hidden>/' "$CONF"
}

setup() {
  if ! mkdir -p "$STATE" 2>/dev/null || [ ! -w "$STATE" ]; then
    die "$STATE is not writable by uid $(id -u). Create it on the host and run with --user $(id -u):$(id -g)."
  fi

  step 'Cadence daemon setup'
  hint 'Writes the server URL, API token, and optional AI settings into the state volume.'
  printf '\n'

  if [ -f "$CONF" ]; then
    printf 'Existing configuration in %s:\n' "$CONF"
    mask
    printf '\nReplace it? [y/N] '
    read -r answer
    case "$answer" in
      y | Y) printf '\n' ;;
      *)
        ok 'keeping the existing configuration'
        exit 0
        ;;
    esac
  fi

  # Preserve an AI configuration when setup is re-run. The key is a secret, so
  # it is never echoed: blank keeps it, and the other values become defaults.
  old_llm_key='' old_llm_provider='' old_llm_model='' old_llm_base=''
  if [ -f "$CONF" ]; then
    old_llm_key=$(sed -n 's/^CAD_LLM_API_KEY=//p' "$CONF" | head -n 1 || true)
    old_llm_provider=$(sed -n 's/^CAD_LLM_PROVIDER=//p' "$CONF" | head -n 1 || true)
    old_llm_model=$(sed -n 's/^CAD_LLM_MODEL=//p' "$CONF" | head -n 1 || true)
    old_llm_base=$(sed -n 's/^CAD_LLM_BASE_URL=//p' "$CONF" | head -n 1 || true)
  fi

  printf '%sServer URL%s (the public origin or a LAN/Tailscale address): ' "$c_bold" "$c_reset"
  read -r server_url
  printf '%sAPI token%s (mint it at /auth/tokens/new on the server): ' "$c_bold" "$c_reset"

  # Hide secrets while they are typed. `stty` only works on a terminal, so a
  # piped setup (for example in a script) keeps the values on stdin.
  hide=0
  if [ -t 0 ] && stty -echo 2>/dev/null; then
    hide=1
    trap 'stty echo 2>/dev/null || true' 0
  fi

  read -r token
  if [ "$hide" = 1 ]; then printf '\n'; fi

  if [ -n "$old_llm_key" ]; then
    hint 'An LLM key is already stored; blank keeps it.'
  else
    hint 'Blank leaves AI features (commit messages, docs) disabled.'
  fi
  printf '%sLLM API key%s (optional): ' "$c_bold" "$c_reset"
  read -r llm_key || llm_key=''

  if [ "$hide" = 1 ]; then
    stty echo 2>/dev/null || true
    trap - 0
    printf '\n'
  fi

  if [ -z "$server_url" ] || [ -z "$token" ]; then
    die 'server URL and API token are required; nothing written'
  fi

  if [ -z "$llm_key" ]; then
    llm_key="$old_llm_key"
  fi

  llm_provider='' llm_model='' llm_base=''
  if [ -n "$llm_key" ]; then
    provider_default="${old_llm_provider:-deepseek}"
    model_default="${old_llm_model:-deepseek-chat}"
    base_default="${old_llm_base:-https://api.deepseek.com}"

    printf 'LLM provider [%s]: ' "$provider_default"
    read -r llm_provider || llm_provider=''
    llm_provider="${llm_provider:-$provider_default}"

    printf 'LLM model [%s]: ' "$model_default"
    read -r llm_model || llm_model=''
    llm_model="${llm_model:-$model_default}"

    printf 'LLM base URL [%s]: ' "$base_default"
    read -r llm_base || llm_base=''
    llm_base="${llm_base:-$base_default}"
  fi

  umask 077
  {
    printf 'CAD_SERVER_URL=%s\nCAD_AUTH_TOKEN=%s\n' "$server_url" "$token"
    if [ -n "$llm_key" ]; then
      printf 'CAD_LLM_API_KEY=%s\nCAD_LLM_PROVIDER=%s\nCAD_LLM_MODEL=%s\nCAD_LLM_BASE_URL=%s\n' \
        "$llm_key" "$llm_provider" "$llm_model" "$llm_base"
    fi
  } >"$CONF"
  chmod 600 "$CONF"

  # Create the database now so the first start is quick and quiet.
  "$RELEASE" eval "Cadence.Daemon.Release.migrate()" >/dev/null

  printf '\n'
  ok "wrote $CONF"
  hint 'mode 0600, inside the state volume; revoke the token from /account if it leaks'

  if [ -n "$llm_key" ]; then
    ok "AI features enabled ($llm_provider/$llm_model)"
  else
    hint 'AI features disabled (no LLM API key)'
  fi

  # Verify the configuration now. A wrong URL, a rejected token, or a missing
  # network flag is otherwise invisible until the first sync pass. Best-effort:
  # the file is written and a registered project keeps committing offline, so a
  # failure is a warning, never an abort.
  printf '\n'
  step 'Server connection'
  set -a
  # shellcheck disable=SC1090
  . "$CONF"
  set +a

  check_output=$("$RELEASE" eval 'IO.inspect(Cadence.Daemon.Release.check_connection())' 2>&1 || true)

  case "$check_output" in
    *'{:error, :unauthorized}'*)
      warn 'the server rejected the token (401)'
      hint 'mint a new one at /auth/tokens/new, then re-run setup'
      ;;
    *'{:error, :certificate}'*)
      warn 'the server certificate is not trusted'
      hint 'set CAD_SYNC_CA_FILE to the issuing CA (DAEMON.md)'
      ;;
    *'{:error, :unreachable}'*)
      warn "cannot reach $CAD_SERVER_URL from this container"
      hint 'check the URL and that the server is reachable from this container'
      hint 'for a server in another local container, join its network and use its service name'
      ;;
    *'{:error, {:http,'*)
      warn "the server answered $(printf '%s' "$check_output" | grep -o '{:error, {:http, [0-9]*}' | tail -n 1)"
      hint 'check the server logs for that request, then re-run setup'
      ;;
    *':ok'*)
      ok "server authenticated ($CAD_SERVER_URL)"
      ;;
    *':not_configured'*)
      warn 'no server URL or token: the daemon will run offline'
      ;;
    *)
      warn 'connection not verified'
      hint "$(printf '%s\n' "$check_output" | grep -v 'TLS :client' | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//' | cut -c1-160)"
      ;;
  esac

  printf '\n'
  step 'Start the daemon'
  hint "docker run -d --name cadence-daemon --restart unless-stopped --user $(id -u):$(id -g) … <image>"
  hint 'or run scripts/cadence-up.sh from a checkout: it configures, starts, registers and prints the project URL'
}

start() {
  if [ -f "$CONF" ]; then
    if [ ! -r "$CONF" ]; then
      die "cannot read $CONF as uid $(id -u). Run setup and the daemon with the same --user."
    fi

    set -a
    # shellcheck disable=SC1090
    . "$CONF"
    set +a
  else
    warn "no $CONF: running offline (no server sync)"
    hint "run '<image> setup' to configure, then restart"
  fi

  # Idempotent; keeps a fresh volume usable without a separate migrate step.
  "$RELEASE" eval "Cadence.Daemon.Release.migrate()" >/dev/null 2>&1 || true

  step 'Cadence daemon'
  hint "socket $STATE/daemon.sock"
  exec "$RELEASE" start
}

case "${1:-start}" in
  setup) setup ;;
  start) start ;;
  *) exec "$@" ;;
esac
