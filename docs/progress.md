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
- [x] Correctness pass A1 — normal commits now parent from the **session
  pointer** (`Session.current_node/1`), falling back to the last committed node
  only before a pointer exists. `CommitQueue` gained `base_node/1`, used by both
  `do_commit/2` and `build_diff_text/2`, so `:CadSwitch` actually changes the
  next commit's parent (was silently chaining off the project tip). Spec §3.2.
- [x] Correctness pass A2 — `Node.created_at` is now `:utc_datetime_usec`
  (migration `create_core_tables` updated; added composite index
  `nodes(project_id, created_at)`), and both `latest_node/1` and `GET /nodes`
  order by `created_at desc, id desc` for deterministic ordering when
  timestamps tie.
- [x] 3 new daemon tests (switch-then-commit parents from pointer; deterministic
  latest-node lookup; deterministic `GET /nodes`). 90 tests total (61 shared +
  29 daemon), all green; `mix format --check-formatted` +
  `mix compile --warnings-as-errors` clean. **Breaking change:** existing
  `~/.local/state/cadence/cadence.db` must be deleted and re-migrated (the
  `create_core_tables` migration was edited in place — pre-release).
- [x] Efficiency pass A3 — `GitStore.build_tree/3` now takes `ignore: [names]`
  (basename match at any depth) and **always** skips `.git`, so nested repos and
  build/dependency dirs are never snapshotted. Daemon passes `CAD_IGNORE`
  (default `_build,deps,node_modules,.venv,venv,__pycache__,.elixir_ls,target`)
  from `config/runtime.exs`. Spec §5.3, §12.6.
- [x] Efficiency pass A4 — auto-commits are non-blocking: `:auto` writes a
  placeholder with `message_pending` and hands the node to `MessageQueue`, which
  now fires the first attempt immediately (new `CAD_LLM_RETRY_INITIAL_MS`) then
  backs off. `CommitQueue` no longer calls the LLM inline (removed
  `build_diff_text/2`/`diff_max_bytes/0` there; diff reconstruction lives only in
  `MessageQueue`). Spec §5.3.
- [x] Added `GitStore.open/2` (read-only handle, no filesystem side effects) and
  switched `MessageQueue`'s diff reconstruction from `init/2` to `open/2`. `init/2`
  was `mkdir_p`-ing on every background retry, which raced with test teardown
  (`File.rm_rf!`). Read paths no longer mutate the store.
- [x] 5 new tests (2 GitStore ignore/`.git`; `open/2` creates nothing; daemon
  ignore propagation; async message fill). 94 tests total (64 shared + 30
  daemon), all green across repeated runs; `mix format --check-formatted` +
  `mix compile --warnings-as-errors` clean.
- [x] A5 — added `Cadence.Daemon.ProjectSupervisor` (`:rest_for_one`) owning each
  project's `{CommitQueue, Watcher}` pair; `ProjectRegistry` now starts one
  supervisor per project, so the watcher failing to boot can no longer orphan a
  running commit queue. Test asserts one supervised unit + registry lookup.
  Spec §5.2.
- [x] B dedup — extracted `Cadence.Shared.Changeset.validate_uuid/2` (Node,
  Project, Membership); `Cadence.Daemon.Env.local_user_id/0` + `ignore_names/0`
  (CommitQueue, Session, Projects); `Cadence.Daemon.Client.expect!/4` so the
  `mix cad.*` tasks share one request/error path; and factor the Neovim plugin's
  project-resolution + node-listing boilerplate (`with_project`, `fetch_nodes`,
  `open_nodes`). Note: Ecto's `validate_change/3` skips `nil` (changeset.ex:2519),
  so the helper only validates present values; required-ness stays in
  `validate_required/2`.
- [x] C — added `config/prod.exs` (the missing file made `MIX_ENV=prod` config
  evaluation fail) and declared `{:hammer, "~> 7.5"}` directly in
  `cadence_daemon/mix.exs`. `MIX_ENV=prod mix compile --warnings-as-errors` now
  exits 0.
- [x] 4 more tests (changeset validator ×4 incl. nil-ignored; ProjectSupervisor).
  99 tests total (68 shared + 31 daemon), green across repeated runs.
- [x] Phase 2a Slice A — `Cadence.Shared.DAG` (shared, `libgraph`-backed):
  `graph/1`, `depths/1` (longest-path layering; melds = deepest parent + 1),
  `edges/1`, `roots/1`, `children/1`, `preview_node/1` (§4.4), and
  `default_node/2` (pointer → most-recent-by-user → preview).
- [x] `Cadence.Daemon.Session.state/1` (read-only `{user_id, session_pointer,
  active_heads}`) and `Session.anchor_node/1` (pointer → user's most-recent →
  preview, via `DAG.default_node/2`). `CommitQueue.base_node/1` now anchors on
  `Session.anchor_node/1`, so a session with no explicit pointer parents from
  the local user's own most-recent node rather than the project-wide tip.
- [x] `GET /graph?project_id=` — 400 missing / 404 unknown project / 200 with
  `project_id`, `session`, `default_node_id`, `preview_node_id`, `nodes` (each
  with `depth`), and `edges`. `GET /nodes` now also returns 404 for an unknown
  project (was `200 []`). No `width` in the API — the client owns it.
- [x] 25 more tests (15 DAG; 6 `Session`; 4 router `/graph`+`/nodes`).
  124 tests total (83 shared + 41 daemon), green; format/`--warnings-as-errors`
  clean. No migration, no config change.
- [x] Phase 2a Slice B — Neovim DAG picker (UI; no daemon change):
  `cadence.nvim/lua/cadence/graph.lua` (pure layout: 2-rows-per-layer, root order
  by recency, layer order by parent barycenter, edge rasterization tagged with
  the child's flag, plus `nearest/3`, `node_at/3`, `default_id/2`);
  `ui.lua` `open_graph/2` renders the left-aligned rail (`clamp(20%, 20, 60)`,
  configurable), per-flag node + edge highlights, `h/j/k/l`+arrow navigation,
  a hover panel (committer/date/flags/message) focusable with `<Tab>`, and a
  union footer. `:CadOpen`/`:CadSwitch` both open the picker (Enter →
  `POST /switch`); new `:CadUnion` (`CR` toggles `✓`, `<C-s>` stubbed). README +
  spec §6.2 updated.
- [x] `cadence.nvim/spec/graph_spec.lua` (pure, runs via
  `nvim --headless -l`) covers linear/branch/meld layout, edge flag-tagging,
  `nearest/3`, `node_at`, `default_id`, pinned glyph, empty project. A headless
  UI smoke (rail + default cursor + hover panel + union toggle) also passes.

## Next
- Phase 2a Slice B2 — diff preview: `Cadence.Shared.Diff` (pure line-diff, no new
  dep), `GET /diff?project_id=&node_id=`, and the GitHub-style color-coded hover
  panel (plus the git author). Then the deferred picker items: layer wrap +
  break marker, §6.3 auto-open on VimEnter, Telescope project picker, and the
  cloud-sync default selection (Phase 2b).
- Remaining audit items (lower priority): derive service timeouts from config
  rather than literals; consider `.gitignore`-style patterns beyond `CAD_IGNORE`;
  `Membership.last_seen_at` is defined but unused; `CommitQueue` still inlines
  `@default_author`; `cadence_server` is still an empty scaffold (Phase 2b).

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
- `GET /graph` is a new daemon endpoint beyond the Phase 1d list; it serves the
  structural DAG (depth/edges/session/default) for the picker. `libgraph` is no
  longer unused — it backs `Cadence.Shared.DAG`.
- `GET /nodes` now returns `404` for an unknown `project_id` (previously
  `200 []`) to match `/spawn`/`/switch`. Both are documented in §13 Phase 2a.
- Session anchoring (§6.3) now applies to commits, not just the picker: with no
  explicit pointer, a commit parents from the *local user's* most-recent node
  (then the preview node), never the project-wide tip. This is what makes a
  synced-but-not-yet-touched machine resume cleanly (Phase 2b).
- Picker rail width deviates from the original §6.2 bound (`min(cols, 80)`): it
  is now `clamp(floor(cols*0.2), 20, 60)`. §6.2 was updated to match.
- Hover is richer than §6.2's "date, message, flag": it now shows committer +
  date/time + flag(s) + message, with a color-coded diff preview planned (B2).

## Last Updated
2026-10-14 — Phase 2a Slice B (Neovim DAG picker: graph.lua + ui.lua +
`:CadUnion`; pure layout spec + headless UI smoke green). Next: Slice B2 (diff
preview) then the deferred picker items.
