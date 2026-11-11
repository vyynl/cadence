# Cadence Release Notes

## 1.0.0 — 2026-11-11

The planned build order (spec §13, Phases 1–8) is complete. Cadence is a
local-first, self-hosted source control system built on a DAG of session nodes.
This is the first release with the documented contract considered stable; the
items still open in spec §16 are optional and listed under **Known
limitations**.

### What ships

**Local daemon (`cadence_daemon`)**
- File watcher with per-OS backends (`fs_inotify` on Linux, `fs_poll`
  elsewhere) and debounced auto-commits; one serialized commit queue per
  project.
- A project directory that disappears is retried instead of crash-looping; a
  broken project can no longer take the project registry (and every other
  project) down with it.
- Git object store (`Cadence.Shared.GitStore`) with pack v2 + idx v2 reads and
  writes, delta chains, and a verified repacker on the server side.
- AI commit messages and doc automation through the configured `CAD_LLM_*`
  client, with Hammer rate limits and background retries. Both are optional.
- Unix-socket API: register projects, list nodes/graph/diff, spawn/switch,
  submit unions, list the local union journal, queue docs sync, and read docs
  diffs.
- Background sync: provisioning, parent-first pushes, existence handshake,
  pulls, LWW preferences, and an optional notification socket.
- `mix cad.*` tasks and the `cadence_daemon` release (ERTS bundled, no Erlang
  distribution; stop with SIGTERM / systemd).

**Server (`cadence_server`)**
- Phoenix 1.8 / LiveView 1.2 public portfolio, full DAG, repository browser,
  MDEx README rendering (sanitized), and member views.
- AshAuthentication: GitHub/Google OAuth in production, a compile-gated demo
  password strategy, and personal access tokens for daemons.
- Proposals and incidents: public read-only proposal links, a member review
  hub, approve/reject with integrity checks, quarantine for secrets and
  sensitive paths, and an incident panel with verify-before-resolve.
- Meld/union pipeline: deterministic union, conflict-only agent calls,
  strict parsing, Elixir/binary guards, result materialization, and a pending
  proposal (never an auto-promoted node).
- Docker actions: a strictly parsed `actions/manifest.json`, a durable run
  queue (per-project concurrency and depth caps), sandboxed containers through
  an allowlisted socket proxy, post-exit logs, artifact downloads, retention,
  and paged run history.
- Storage: pack-aware reads, background repacking with a timeout and cooldown,
  and the sync existence handshake.
- Release artifact: `docker/Dockerfile` + `docker-compose.prod.yml` with a
  one-shot migration service; `mix release cadence`.

**Neovim plugin (`cadence.nvim`)**
- `:CadOpen`, `:CadSpawn`, `:CadSwitch`, `:CadUnion`, `:CadProposals`,
  `:CadDocSync`, `:CadDocDiff`, the DAG picker, and hover diffs.

**Demo stack**
- `docker compose up --build` gives a seeded, browsable server on
  <http://localhost:4000> (`docs/demo.md`).

### Upgrade notes

- **Back up `CAD_STATE_DIR` before upgrading the daemon.** This release's
  SQLite schema is not purely additive: `Project.actions_manifest` is dropped.
  Roll the release and the database back together; a rollback needs a source
  checkout.
- Run the daemon migration once after upgrading:
  `~/.local/share/cadence/bin/cadence_daemon eval "Cadence.Daemon.Release.migrate()"`
  (source checkout: `mix ecto.migrate -r Cadence.Daemon.Repo`). A boot on an
  unmigrated database is safe but syncs nothing.
- Rebuild the server image so it picks up the shared `config/runtime.exs`
  split (the daemon release no longer requires the server's prod variables).
  Older images still work and still require them.
- `ash_postgres` moved to 2.15.2 (the 2.14 series is retired by Hex).
- The daemon release is built per OS/arch (`exqlite` ships a precompiled NIF).
  Linux needs `inotifywait` (`inotify-tools`) or `CAD_WATCH_BACKEND=fs_poll`.

### Editor independence

Neovim is optional. Nodes are created by the daemon's watcher from working-tree
changes, and the sync worker pushes them. Any process writing inside a
registered project directory — an IDE, another editor, a script, an AI agent —
produces nodes. The plugin only adds the DAG picker and convenience commands;
its daemon endpoints are plain HTTP over `daemon.sock` (`docs/daemon-setup.md`
§9).

### Known limitations (spec §16)

- Conflict-bearing melds and doc generation have not been smoke-tested live
  with a real `CAD_LLM_API_KEY`; conflict-free unions skip the model.
- Web docs review (approving/rejecting generated docs) is deferred; the web UI
  shows a read-only docs badge.
- Action logs are captured after the container exits; there is no live stream.
- Pack consolidation / a multi-pack index is not implemented; each repack run
  adds a pack.
- Public proposal rendering is uncached and the sync API has no general rate
  limit beyond the meld limiter; keep the server behind normal edge protection
  if exposed publicly.
- Image publishing/CI is operator-side; `Project.docker_image` has no admin
  writer; action containers run in the host user namespace with no `/out`
  quota, so the actions volume must be size-limited.
- Multi-node server fan-out, the public-preview auth decision, and the cloud
  backup strategy remain open.
- A `burrito` single-file daemon artifact is not implemented (it would need a
  spec §11 dependency row).
