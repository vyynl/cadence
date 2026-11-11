# Daemon setup

The daemon is the local half of Cadence. It watches a project's working tree,
commits snapshots to a local Git store, serves the Neovim plugin over a Unix
socket, and — when configured — syncs nodes to a Cadence server. This guide
takes a machine to a registered project, either from a built release
(recommended for daily use) or from a source checkout (development).

The canonical configuration contract is spec §12.2/§12.6. The server side of
the demo stack is in `demo.md`; this guide assumes a server is already running.

## 1. Prerequisites

**Release install (recommended):** the artifact bundles ERTS, so the target
machine needs no Elixir or Erlang. Build it on the machine that will run it (or
a matching OS/arch): `exqlite` ships a precompiled SQLite NIF, so a Linux
x86_64 release does not run on macOS or arm64.

- On Linux the default watcher needs `inotifywait` from `inotify-tools`
  (`apt install inotify-tools`, `dnf install inotify-tools`, or the equivalent).
  Set `CAD_WATCH_BACKEND=fs_poll` to run without it (the watcher polls every
  second instead).
- On macOS the default is `fs_poll` (also a 1 s poll), so no extra package is
  needed. `CAD_WATCH_BACKEND=fs_mac` selects the native listener instead; it is
  bundled only when the release is built on macOS with the Xcode command-line
  tools installed.

**Source checkout (development):** Elixir 1.20+ and OTP with `mix` on `PATH`.

Both paths also need:

- A Cadence server URL (optional: without one the daemon runs fully offline).
- The working directory of the project you want to track.
- Neovim 0.9+ if you want the plugin (`cadence.nvim/README.md`).

## 2. Pick a state directory

The daemon keeps everything under `CAD_STATE_DIR` (default
`~/.local/state/cadence`):

| Path | Purpose |
|---|---|
| `cadence.db` | SQLite metadata (projects, nodes, sync ledger) |
| `daemon.sock` | Unix socket used by the Neovim plugin (and `mix cad.*` tasks in a source checkout) |
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

## 5. Install the daemon

### Release (recommended)

Build the artifact on the machine that will run it:

```bash
MIX_ENV=prod mix release cadence_daemon
```

The result is `_build/prod/rel/cadence_daemon` (`bin/cadence_daemon version`
prints the release version). Install it under a stable path, for example
`~/.local/share/cadence`:

```bash
mkdir -p ~/.local/share
mv ~/.local/share/cadence ~/.local/share/cadence.bak 2>/dev/null || true
cp -a _build/prod/rel/cadence_daemon ~/.local/share/cadence
~/.local/share/cadence/bin/cadence_daemon version
```

The release directory is replaceable; `CAD_STATE_DIR` (SQLite, Git stores,
socket) lives outside it and is never touched by an upgrade. A systemd user
unit that uses the same env file is in §7.

### Source checkout (development)

Run the `mix` commands from the umbrella root with the same environment as the
daemon.

## 6. Migrate the local database once

Release:

```bash
~/.local/share/cadence/bin/cadence_daemon eval "Cadence.Daemon.Release.migrate()"
```

Source checkout:

```bash
mix ecto.migrate -r Cadence.Daemon.Repo
```

Both resolve `CAD_STATE_DIR` through `config/runtime.exs`. A fresh state
directory must exist first; create it owner-only so there is no permissive
window (the release `migrate/0` creates it for you):

```bash
mkdir -m 700 -p "${CAD_STATE_DIR:-$HOME/.local/state/cadence}"
```

Re-run the migration after upgrading the daemon: a new one is not applied by a
plain boot. The release entry point is safe to run repeatedly — it reports
`Migrations already up` and changes nothing.

Migrations are **not** guaranteed to be additive: a release that removes a
schema field also drops the column (8b removes `Project.actions_manifest`), and
an older release cannot read a newer schema. Back up `CAD_STATE_DIR` before an
upgrade — SQLite is `cadence.db` plus its `-wal`/`-shm` siblings — and roll the
release and the database back together. A migration rollback needs a source
checkout (`mix ecto.rollback -r Cadence.Daemon.Repo --step 1`).

A daemon booted before migrating is safe: rehydration logs a
`… skipped before migrations: no such table: <table>` warning for each queue,
skips the sync backfill, and keeps idling. Nothing syncs until the database is
migrated and the daemon is restarted.

## 7. Start the daemon

Release:

```bash
~/.local/share/cadence/bin/cadence_daemon start
```

`start` runs in the foreground and logs to stdout, which suits a process
manager. `bin/cadence_daemon daemon` detaches instead. The daemon release runs
without Erlang distribution (no epmd or distribution port, and no distribution
cookie is used), so `bin/cadence_daemon stop`/`remote` are unavailable: stop it
with SIGTERM — `systemctl --user stop cadence-daemon`, `kill <pid>`, or Ctrl-C
in the foreground. The release shuts down gracefully on SIGTERM.

Source checkout:

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

### systemd user unit

`EnvironmentFile` reads the same `~/.config/cadence/env` file (systemd accepts
`KEY=value` lines and `#` comments):

```ini
# ~/.config/systemd/user/cadence-daemon.service
[Unit]
Description=Cadence daemon
After=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/cadence/env
Environment=CAD_STATE_DIR=%h/.local/state/cadence
ExecStart=%h/.local/share/cadence/bin/cadence_daemon start
Restart=on-failure

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now cadence-daemon
journalctl --user -u cadence-daemon -f
```

A system service (`User=you`, unit in `/etc/systemd/system`) does not expand
`%h` to the service user's home — it resolves to the service manager's home
(usually `/root`). Use absolute paths (`/home/you/...`) and set
`Environment=HOME=/home/you` there.

## 8. Register a project

Release (use an absolute work directory; the shell does not expand `~` inside
the eval string; `IO.inspect` prints the created project):

```bash
~/.local/share/cadence/bin/cadence_daemon eval \
  'IO.inspect(Cadence.Daemon.Release.register("My Project", "my-project", "/home/you/code/my-project"))'
```

Source checkout:

```bash
mix cad.register "My Project" my-project ~/code/my-project
```

- The daemon must be running; both forms talk to `daemon.sock`.
- `WORK_DIR` must exist. Registration starts the watcher; the first **file
  change** after registration is committed once the tree has been idle for
  `CAD_WATCH_DEBOUNCE_MS` (default 2 s). Registering an unchanged project
  produces no node — edit a file (or touch one) to start the history.
- The same operation is available as `POST /projects` on the daemon socket.

## 9. Neovim (optional)

Install the plugin as described in `cadence.nvim/README.md`. It resolves the
socket the same way (`$CAD_STATE_DIR/daemon.sock`) and auto-opens the DAG when
Neovim starts inside a registered project.

**Neovim is not required to create or push nodes.** Nodes come from the
daemon's watcher, not the plugin: a file change in a registered project is
debounced, snapshotted into the local Git store, committed as a node, and
enqueued for sync (`apps/cadence_daemon/lib/cadence/daemon/watcher.ex` →
`commit_queue.ex` → `sync_ledger.ex` → `sync_worker.ex`). Any writer works — an
IDE, `vim`, a shell script, a build tool, or an AI agent such as OpenCode.

The plugin adds the DAG picker and these conveniences. Every one has a socket
or `mix` equivalent, so the same operations are scriptable without Neovim:

| Plugin command | Without Neovim |
|---|---|
| `:CadOpen` / `:CadSwitch` | `mix cad.switch SLUG NODE_ID`, or `POST /switch` on `daemon.sock` |
| `:CadSpawn` | `mix cad.spawn SLUG [NAME]`, or `POST /spawn` |
| `:CadUnion` | `POST /union` with `{"project_id", "parent_node_ids"}` |
| `:CadProposals` | `GET /proposals?project_id=…` |
| `:CadDocSync` | `POST /docs/sync` |
| `:CadDocDiff` | `GET /docs/diff?project_id=…&node_id=…` |

```bash
# Write through the socket without any editor plugin.
curl -sS --unix-socket "$CAD_STATE_DIR/daemon.sock" \
  http://localhost/union -H 'content-type: application/json' \
  -d '{"project_id":"…","parent_node_ids":["…","…"]}'
```

Pushes are automatic when the daemon is configured (`CAD_SYNC_ENABLED`,
`CAD_SERVER_URL`, `CAD_AUTH_TOKEN`). Enqueueing a node wakes the sync worker;
there is no separate "push now" command, and a project with no file changes
creates no node. `CAD_IGNORE` keeps build directories (`_build`, `deps`,
`node_modules`, …) out of history, which matters when an agent's tooling writes
inside the project.

## Upgrading the daemon

1. Stop the daemon (`systemctl --user stop cadence-daemon`; for a foreground
   start use Ctrl-C, or `kill <pid>`).
2. Replace the release directory (§5). Keep the old directory until the new
   one starts.
3. Run the migration entry point (§6). It is a no-op when there is nothing new;
   it is not necessarily additive (see the note in §6).
4. Start the daemon again.

`CAD_STATE_DIR` is never inside the release directory, so project data, the
socket, and the sync ledger survive an upgrade untouched.

## Troubleshooting

| Symptom | Check |
|---|---|
| `no such table: …` warnings | The daemon database has not been migrated. Run step 6 and restart. |
| Socket missing / plugin cannot connect | `CAD_STATE_DIR` must match between the daemon shell and Neovim. Confirm the daemon is running and `daemon.sock` exists. |
| Watcher logs a `file_system` bootstrap error | Linux needs `inotifywait` (`inotify-tools`); on any OS set `CAD_WATCH_BACKEND=fs_poll`. |
| Release fails to start with a NIF / `Exec format` error | The artifact was built for another OS/arch. Rebuild on the target machine (§5). |
| `could not find user home` on boot | The process has no `HOME`. Set `CAD_STATE_DIR` explicitly (or provide `HOME`). |
| Sync never starts | `CAD_SYNC_ENABLED` must not be `false`, and both `CAD_SERVER_URL` and `CAD_AUTH_TOKEN` must be set in the daemon's environment. |
| `401` from the server | The token was revoked, mistyped, or belongs to another server. Mint a new one at `/auth/tokens/new`. |
| `mix ecto.migrate` uses the wrong database | Set `CAD_STATE_DIR` in the same shell; runtime config is read by the task too. |
| Env file changes have no effect | The file is not read automatically. Source it (`set -a; . ~/.config/cadence/env; set +a`) or use `EnvironmentFile` (§7). |
