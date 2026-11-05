#!/usr/bin/env bash
# Vendor (or update) the Elixir/Phoenix agent skills for OpenCode.
#
# The plugin is kept out of git: it is its own repository, so committing it
# would record a broken gitlink. Run this script after a fresh clone and after
# pulling plugin updates. It is idempotent.
#
#   scripts/setup-opencode.sh          # install or update
#   scripts/setup-opencode.sh --check  # report state, change nothing
#
# Override the upstream with CAD_PLUGIN_REPO.

set -euo pipefail

REPO_URL="${CAD_PLUGIN_REPO:-https://github.com/oliver-kriska/claude-elixir-phoenix.git}"
DEST=".opencode/skills/elixir-phoenix"
SKILLS_DIR="$DEST/targets/opencode/skills"

cd "$(dirname "$0")/.."

check_only=0
if [[ "${1:-}" == "--check" ]]; then
  check_only=1
fi

if [[ -d "$DEST/.git" ]]; then
  if [[ "$check_only" == 1 ]]; then
    echo "installed: $DEST ($(git -C "$DEST" rev-parse --short HEAD))"
  else
    echo "updating $DEST"
    git -C "$DEST" fetch --filter=blob:none origin
    git -C "$DEST" sparse-checkout set targets/opencode
    git -C "$DEST" pull --ff-only
  fi
elif [[ -e "$DEST" ]]; then
  echo "error: $DEST exists but is not a git checkout" >&2
  echo "       remove it and re-run this script" >&2
  exit 1
else
  if [[ "$check_only" == 1 ]]; then
    echo "missing: $DEST (run scripts/setup-opencode.sh)" >&2
    exit 1
  fi
  echo "cloning $REPO_URL into $DEST"
  git clone --filter=blob:none --sparse "$REPO_URL" "$DEST"
  git -C "$DEST" sparse-checkout set targets/opencode
fi

if [[ ! -d "$SKILLS_DIR" ]]; then
  echo "error: $SKILLS_DIR not found after setup" >&2
  exit 1
fi

count=$(find "$SKILLS_DIR" -name SKILL.md -type f | wc -l | tr -d ' ')
version=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$DEST/package.json" | head -n1)

echo "ok: $count skills from elixir-phoenix ${version:-unknown}"
echo "   load one in OpenCode with @phx-plan (or the skill tool)"
