# Cadence — Progress

## Current Phase
Phase 1f complete → moving into Phase 2a (DAG picker)

## Done
- [x] Read spec + AGENTS.md; audited and resolved all scaffold blockers.
- [x] Spec revisions: LLM client = `axiom_ai` (DeepSeek); graph model =
      `libgraph`; `Hammer` lives in `cadence_shared`; `GitStore` shared-only;
      config model = env vars / `.env` (TOML dropped); §11 dependency table
      corrected.
- [x] Scaffolded umbrella: root `mix.exs`, `.formatter.exs`, `config/config.exs`,
      and the three apps (`cadence_shared`, `cadence_daemon`, `cadence_server`)
      with placeholder modules. Server has only `cadence_shared` (Phoenix deferred
      to Phase 2b).
- [x] `Cadence.Shared.GitStore` — fully absorbed the `gitex` object-store logic
      into a DAG-specialized, ref-less, native module. Implements Git's public
      object format (blob/tree/commit, SHA-1, zlib) with standard modes
      (`100644`/`40000`). API: `init/2` (bare/working), `write_blob/read_blob`,
      `write_tree/build_tree/read_tree`, `write_commit/read_commit` (explicit
      parents, no refs), `checkout/3`. One-line attribution to `awetzel/gitex`
      (MIT) retained in the module doc. Pruned: refs, HEAD, tags, packfile/delta
      reading, history/align.
- [x] 17 ExUnit tests for `GitStore`, including canonical-SHA assertions
      (`hello world\n` blob = `3b18e512…`, empty tree = `4b825dc6…`) and a full
      round-trip (build_tree → commit → checkout). All green.
- [x] `mix compile` clean; `mix format` clean.
- [x] Spec evolved toward multi-user collaboration: clarified that the meld/union
      *is* the DAG's merge (2+ parents) and that "merge into a branch" is
      replaced by **promotion** to a flag; added `Approve` to the role matrix
      (§4.5), lightweight `team`/`approver`/`supervisor` metadata (§4.6), and a
      proposals/review/promotion lifecycle with shareable links (§6.6); widened
      the vision from "single dev + trusted circle" to "single dev / team /
      self-hosted company" (§1, §14).
- [x] Storage-engineering direction captured: `parents` = `uuid[]` + GIN index
      with `node_edges` table as the documented migration path (§4.1);
      `session_metadata` must not inline diffs (§4.1); added **Phase 7 —
      Storage engineering** (lossless delta repack + sync object negotiation,
      never pruning history) (§13); open trigger/migration threshold in §16.

- [x] `Cadence.Shared.Node`, `.Project`, `.Membership` Ecto schemas + changesets
      (`apps/cadence_shared/lib/cadence/shared/`). `Node.parents` as
      `{:array, Ecto.UUID}`; `flags` as `{:array, Ecto.Enum}` (kebab-case atoms
      `:"in-progress"` etc.); `session_metadata`/`docs_schema`/`actions_manifest`
      as `:map`. `Membership` uses a composite primary key `(user_id, project_id)`
      (`@primary_key false`), carries §4.6 `approver`/`team`/`supervisor`.
- [x] `Cadence.Shared.Sync.*` protocol structs (7 modules): `PushNodes`,
      `PushNodesResponse`, `PullNodes`, `PullNodesResponse`, `PushPreferences`,
      `Union`, `UnionResponse` — plain `defstruct` + `@enforce_keys` +
      `@derive Jason.Encoder`, matching spec §10.6.
- [x] 44 ExUnit tests total (17 GitStore + 27 new: schema changesets + sync
      struct encoding). All green; `mix compile --warnings-as-errors` clean.
- [x] `Cadence.Daemon.Repo` (SQLite via `ecto_sqlite3`) + migration
      `create_core_tables` (`projects`, `nodes`, `memberships` composite PK).
      Config split into `config/{config,dev,test}.exs`; daemon DB at
      `CAD_STATE_DIR` (default `~/.local/state/cadence/cadence.db`), test DB
      `:memory:` + `pool_size: 1`.
- [x] `Cadence.Daemon.CommitQueue` GenServer (per project): `build_tree` →
      `write_commit` (static message, `flags: [:"in-progress"]`,
      `docs_state: :pending`) → `Repo.insert Node` with `parents` chained from
      `head`. Git object store lives *outside* the work dir (avoids
      `build_tree` recursion). Synchronous `commit/2`.
- [x] `Cadence.Daemon.Watcher` GenServer: `file_system` worker + `Process.send_after`
      debounce (`CAD_WATCH_DEBOUNCE_MS`) → `CommitQueue.commit/2`. Backend
      configurable (`CAD_WATCH_BACKEND`).
- [x] `Cadence.Daemon.ProjectRegistry` (DynamicSupervisor): `start_project/1`
      boots a `{CommitQueue, Watcher}` pair per project.
- [x] Security hardening: `Cadence.Daemon.Dirs.ensure!/1` creates state/git dirs
      `0700` (app-start verified); `GitStore.checkout/3` now rejects
      path-traversal tree entry names (`..`, `/`, absolute) with a test.
- [x] 3 daemon ExUnit tests (repo round-trip incl. array/map/enum serialization,
      commit-queue parent chaining, watcher end-to-end via `:fs_poll`). All
      green; `mix format --check-formatted` + `mix compile --warnings-as-errors`
      clean (48 tests total).
- [x] Spec terminology: renamed **fork → spawn** across the spec (§1, §3
      term table, §3.1/§3.2, §4.5 role matrix, §6 header/§6.1/§6.4, §13, §16)
      to stay consistent with the node/DAG model ("no branches, just nodes and
      flags"). `:CadFork` → `:CadSpawn`, `POST /fork` → `POST /spawn`. "switch"
      kept as-is.
- [x] `Cadence.Daemon.Session` — per-user session-pointer/active-heads helpers
      over `Membership`: `ensure_membership!/1`, `current_node/1`, `switch/2`,
      `spawn_after/3`.
- [x] `Cadence.Daemon.ProjectLocation` schema + migration
      (`20261014000000_create_project_locations.exs`) — machine-local
      `{project_id, work_dir, git_dir}` mapping.
- [x] `Cadence.Daemon.Projects` — `register_project/1` (validate + persist
      Project/Location + boot `{CommitQueue, Watcher}` + seed owner membership),
      `list_projects/0`, `rehydrate/0` (boot-time restart of registered projects).
- [x] `ProjectRegistry` extended: queues registered via `Registry`
      (`Cadence.Daemon.Queues`, keyed by `project_id`); `lookup_queue/1`.
- [x] `CommitQueue.spawn/2` — spawns a `sandbox` child reusing the current
      node's tree (spec §6.4), advances pointer + adds parent to active heads.
- [x] `Cadence.Daemon.API` + `API.Router` — Bandit + Plug on a Unix socket at
      `CAD_STATE_DIR/daemon.sock`; socket chmod `0600` after bind. Endpoints:
      `GET /projects`, `POST /projects`, `GET /nodes`, `POST /spawn`,
      `POST /switch`, `GET /health`.
- [x] `Cadence.Daemon.Client` — raw HTTP/1.1 over the Unix socket + `mix cad.*`
      tasks (`cad.projects`, `cad.register`, `cad.nodes`, `cad.spawn`,
      `cad.switch`).
- [x] 14 new daemon tests (session, projects, API router via `Plug.Test`,
      API integration over a real socket asserting `0600` + register→commit→
      switch→spawn round-trip). 62 tests total, all green;
      `mix format --check-formatted` + `mix compile --warnings-as-errors` clean.
- [x] Closed the §5.3 spec/impl gap: `CommitQueue.do_commit/2` now calls
      `Session.commit_after/2` to set `session_pointer = new_node.id` and drop
      the superseded parent from `active_heads` on a normal commit (§3.2, §5.3).
      Tests added (`commit_queue_test`, `session_test`).
- [x] Neovim plugin skeleton at `cadence.nvim/` (proper plugin, resolves §16
      distribution question → plugin skeleton with lazy.nvim usage):
      `plugin/cadence.lua` (defines `:CadOpen`/`:CadSpawn`/`:CadSwitch`),
      `lua/cadence/init.lua` (`setup/0`, socket-path resolution:
      `setup({socket_path})` → `$CAD_STATE_DIR` → `~/.local/state/cadence`),
      `lua/cadence/client.lua` (HTTP-over-unix-socket via `plenary.curl` +
      `--unix-socket`), `lua/cadence/ui.lua` (floating-window list/picker),
      `README.md`. Project resolved by matching `cwd` to a registered
      `work_dir`.
- [x] Verified end-to-end against a live daemon: `GET /projects` via the Lua
      client (status 200), and a headless-nvim run where a watcher auto-commit
      became the current node (confirms the commit→pointer fix), then `:CadOpen`
      (floating window), `:CadSpawn explore` (nodes 1→2), `:CadSwitch` all
  clean. 64 tests total green; `mix format --check-formatted` +
  `mix compile --warnings-as-errors` clean.

- [x] Phase 1f — AI commit messages: `Cadence.Shared.LLM` (wraps `AxiomAi`'s
  DeepSeek provider; nil-tolerant API key → `:not_configured` fallback),
  `Cadence.Shared.LLM.CommitMessage` (prompt build + `SUMMARY/FLAG/DETAIL`
  parser + `clamp_flag/1` that never auto-promotes to `functioning`),
  `priv/prompts/commit_message.txt` (§5.5 template), and
  `GitStore.diff_trees/3` (added/modified/deleted by SHA) + `diff_to_text/2`
  (size-capped). Daemon: `LLMRateLimit` (Hammer ETS), `AgentWorker`
  (Task.Supervisor; rate-limit + timeout), `MessageQueue` (retry-with-backoff +
  boot `rehydrate` via `session_metadata["message_pending"]`). `CommitQueue.commit/2`
  takes `:auto` (default) — block-with-timeout generation, placeholder +
  `message_pending` + enqueue on failure. Supervised in `Application`.
- [x] Config moved to runtime evaluation: new `config/runtime.exs` reads all
  `CAD_*` (daemon tunables guarded by `config_env() != :test`; LLM client
  config unguarded); `config/config.exs` shrunk to static-only; `dev.exs`
  emptied; `.env.example` documents `CAD_LLM_*` + retry vars. No secrets
  inlined (only `System.get_env`/`Application.get_env` references).
- [x] 87 tests total (61 shared + 26 daemon), all green; `mix format
  --check-formatted` + `mix compile --warnings-as-errors` clean.

## Next
- Phase 2a — DAG picker: render nodes + edges in the Neovim floating window
  with the elbow layout (§7.3), navigation/hover tooltips, default-selection
  logic (§6.3), and `:CadUnion` picker mode (UI only). See spec §13 Phase 2a.

## Blocked
- (none)

## Spec Deltas
- `POST /projects` is an addition beyond the four endpoints listed in §13
  Phase 1d (spec still lists only `GET /nodes`, `POST /spawn`, `POST /switch`,
  `GET /projects`). Registration/discovery needed it: nothing could register a
  project otherwise. Also new: the daemon persists `project_locations` and
  rehydrates registered projects on boot. Consider updating §5.1/§13.
- Neovim plugin transport uses `plenary.nvim`'s `curl` wrapper with the
  `--unix-socket` raw arg (spec §11 already lists plenary.nvim; `curl` is an
  implicit PATH dependency worth noting in §11). The §16 "plugin distribution"
  open decision is now resolved in favor of a plugin skeleton (`cadence.nvim/`).
- `CAD_LLM_API_KEY` is treated as optional for the daemon (nil-tolerant, falls
  back to a static message) rather than the "required" flag in §12.6. The
  daemon must boot and auto-commit without an LLM configured (local-first).
  Consider softening §12.6 for the daemon.

## Last Updated
2026-10-14 — session wrapped: Phase 1f complete (AI commit messages + runtime config)
