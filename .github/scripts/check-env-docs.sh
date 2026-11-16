#!/usr/bin/env bash
# Guard: every CAD_* variable that appears in a compose stack must be
# documented in the canonical environment reference.
#
#   .env.example          the server / reference stack
#   .env.daemon.example   the daemon
#
# Those two files are the only place a variable's meaning is described, so a
# new knob that lands in a compose file but not in them is invisible to the
# operator. The allowlist below covers names that are deliberately documented
# at their use site instead: values the stack derives, fixes, or only a compose
# caller sets.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

env_files=(.env.example .env.daemon.example)
for f in "${env_files[@]}"; do
  [ -f "$f" ] || { echo "missing env reference: $f" >&2; exit 1; }
done

shopt -s nullglob
compose_files=(docker-compose*.yml examples/*.yaml)
shopt -u nullglob

if [ "${#compose_files[@]}" -eq 0 ]; then
  echo "no compose files found" >&2
  exit 1
fi

# name|reason
allowlist=(
  "CAD_DATABASE_URL|derived by the secrets service from CAD_DB_*"
  "CAD_GENERATED_ADMIN_PASSWORD|secret handed between the secrets and bootstrap services"
  "CAD_DOCKER_SOCKET|the stack's own socket-proxy URL (docker-proxy:2375)"
  "CAD_GIT_STORE_PATH|fixed container path (/data/git)"
  "CAD_ARTIFACT_PATH|fixed container path (/data/artifacts)"
  "CAD_ACTIONS_VOLUME_PATH|fixed container path (/data/actions)"
  "CAD_DAEMON_IMAGE|compose knob from the shell, documented in docker-compose.daemon.yml"
  "CAD_DEMO_HINTS|demo stack only, documented in docker-compose.demo.yml"
)

is_allowed() {
  local entry
  for entry in "${allowlist[@]}"; do
    [ "${entry%%|*}" = "$1" ] && return 0
  done
  return 1
}

is_documented() {
  local name="$1" f
  for f in "${env_files[@]}"; do
    grep -qw -- "$name" "$f" && return 0
  done
  return 1
}

checked=0
skipped=()
missing=()

while IFS= read -r name; do
  if is_allowed "$name"; then
    skipped+=("$name")
    continue
  fi

  checked=$((checked + 1))
  is_documented "$name" || missing+=("$name")
done < <(grep -hoE 'CAD_[A-Z0-9_]+' "${compose_files[@]}" | sort -u)

echo "checked ${checked} variables across ${#compose_files[@]} compose files"
echo "allowlisted ${#skipped[@]} internal names: ${skipped[*]:-none}"

if [ "${#missing[@]}" -gt 0 ]; then
  echo >&2
  echo "undocumented CAD_* variables (add each to .env.example or .env.daemon.example):" >&2
  for name in "${missing[@]}"; do
    echo "  ::error::$name" >&2
  done
  exit 1
fi

echo "OK: every checked variable is documented in the env reference"
