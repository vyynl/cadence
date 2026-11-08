# Daemon setup

The daemon is the local half of Cadence. It watches a project's working tree,
commits snapshots to a local Git store, serves the Neovim plugin over a Unix
socket, and — when configured — syncs nodes to a Cadence server. This guide
takes a fresh checkout to a registered project.

The canonical configuration contract is spec §12.2/§12.6. The server side of
the demo stack is in `demo.md`; this guide assumes a server is already running.

## 1. Prerequisites

- Elixir 1.20+ and OTP (`mix` on `PATH`).
- A Cadence server URL (optional: without one the daemon runs fully offline).
- The working directory of the project you want to track.
- Neovim 0.9+ if you want the plugin (`cadence.nvim/README.md`).

## 2. Pick a state directory

The daemon keeps everything under `CAD_STATE_DIR` (default
`~/.local/state/cadence`):

| Path | Purpose |
|---|---|
| `cadence.db` | SQLite metadata (projects, nodes, sync ledger) |
| `daemon.sock` | Unix socket used by the Neovim plugin and `mix cad.*` tasks |
| `git/` | Per-project bare Git object stores |

The directory is created with owner-only (`0700`) permissions on first boot.
Set `CAD_STATE_DIR` to move it (for example to a backup-friendly disk).

## 3. Mint a daemon token (server only)

1. Sign in to the server. In production this is the configured OAuth provider;
   in the demo stack use the password accounts at `/sign-in` (`demo.md`).
2. Open `/auth/tokens/new`.
3. Name the key after the machine (for example `laptop`) and create it.
4. Copy the plaintext key now. The server stores only a SHA-256 hash and the
   value is shown **once**.

The key is a personal access token for the sync API (spec §10.1). Never put it
in `config/`, source, or a commit.

## 4. Configure the environment

The daemon reads environment variables only (spec §12.6); it does **not**
parse the env file itself. Put the values in `~/.config/cadence/env` with
owner-only permissions, then source it in the shell that starts the daemon:

```bash
mkdir -p ~/.config/cadence
$EDITOR ~/.config/cadence/env     # contents below
chmod 600 ~/.config/cadence/env
```

```bash
# ~/.config/cadence/env
CAD_SERVER_URL=https://cadence.example.com
CAD_AUTH_TOKEN=cad_...
CAD_SYNC_ENABLED=true

# Optional
# CAD_STATE_DIR=$HOME/.local/state/cadence
# CAD_SYNC_CHANNEL_ENABLED=true        # notification socket; polling still works when false
# CAD_LOCAL_USER_ID=00000000-0000-0000-0000-000000000000
#
# AI commit messages and doc generation (spec §12.6)
# CAD_LLM_PROVIDER=deepseek
# CAD_LLM_API_KEY=...
# CAD_LLM_MODEL=deepseek-chat
# CAD_LLM_BASE_URL=https://api.deepseek.com
```

```bash
set -a; . ~/.config/cadence/env; set +a
```

- **Offline mode:** leave `CAD_SERVER_URL` and `CAD_AUTH_TOKEN` unset (or set
  `CAD_SYNC_ENABLED=false`). Everything except sync still works.
- **AI keys are optional for core use:** without `CAD_LLM_*` the daemon still
  commits; it skips AI commit messages and doc generation.
- `CAD_SYNC_CHANNEL_ENABLED=false` disables only the optional notification
  socket; background polling continues.

## 5. Migrate the local database once

```bash
mix ecto.migrate -r Cadence.Daemon.Repo
```

Run this from the umbrella root with the same environment as the daemon (it
resolves `CAD_STATE_DIR` through `config/runtime.exs`). A fresh state directory
is created automatically; if you migrate before the first boot, create it
owner-only first so there is no permissive window:

```bash
mkdir -m 700 -p "${CAD_STATE_DIR:-$HOME/.local/state/cadence}"
```

Re-run the migration after upgrading the daemon: migrations are additive and a
new one (for example the `:CadProposals` journal) is not applied by a plain
boot.

A daemon booted before migrating is safe: rehydration logs a
`… skipped before migrations: no such table: <table>` warning for each queue,
skips the sync backfill, and keeps idling. Nothing syncs until the database is
migrated and the daemon is restarted.

## 6. Start the daemon

```bash
mix run --no-start --no-halt -e '
  case Application.ensure_all_started(:cadence_daemon) do
    {:ok, _} -> :ok
    {:error, reason} -> IO.inspect(reason, label: "cadence_daemon failed to start"); System.halt(1)
  end'
```

- `--no-start` stops Mix from booting the umbrella's other applications (the
  Phoenix server); the expression starts only `cadence_daemon`. The `case`
  makes a failed start exit instead of leaving a VM alive with no daemon.
- Keep it in a dedicated terminal or under a process manager. It logs to
  stdout and binds `$CAD_STATE_DIR/daemon.sock`. Use one daemon per state
  directory: a second instance removes and rebinds the socket, leaving the
  first without an API, and both would share `cadence.db` and `git/`.

## 7. Register a project

```bash
mix cad.register "My Project" my-project ~/code/my-project
```

- The daemon must be running; the task talks to `daemon.sock`.
- `WORK_DIR` must exist. Registration starts the watcher; the first snapshot is
  committed after `CAD_WATCH_DEBOUNCE_MS` (default 2 s) of idle time.
- The same operation is available as `POST /projects` on the daemon socket.

## 8. Neovim

Install the plugin as described in `cadence.nvim/README.md`. It resolves the
socket the same way (`$CAD_STATE_DIR/daemon.sock`) and auto-opens the DAG when
Neovim starts inside a registered project.

## Troubleshooting

| Symptom | Check |
|---|---|
| `no such table: …` warnings | The daemon database has not been migrated. Run step 5 and restart. |
| Socket missing / plugin cannot connect | `CAD_STATE_DIR` must match between the daemon shell and Neovim. Confirm the daemon is running and `daemon.sock` exists. |
| Sync never starts | `CAD_SYNC_ENABLED` must not be `false`, and both `CAD_SERVER_URL` and `CAD_AUTH_TOKEN` must be set in the daemon's environment. |
| `401` from the server | The token was revoked, mistyped, or belongs to another server. Mint a new one at `/auth/tokens/new`. |
| `mix ecto.migrate` uses the wrong database | Set `CAD_STATE_DIR` in the same shell; runtime config is read by the task too. |
| Env file changes have no effect | The file is not read automatically. Source it (`set -a; . ~/.config/cadence/env; set +a`) before `mix run`. |
