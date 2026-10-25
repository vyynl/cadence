# Cadence — Progress

## Current Phase
Phase 3b-2 — repository browser + README + public secret filtering

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
- [x] Phase 2a Slice B2a — diff backend: `Cadence.Shared.Diff` (line diff via the
  stdlib `List.myers_difference/2`, context hunks with a `…` skip marker, binary
  guard, per-file/file caps — no new dependency) and `Cadence.Daemon.NodeDiff`
  (node vs. first parent through `GitStore.diff_trees/3`). `GET /diff` returns
  400/404/200 with `{node_id, base_node_id, truncated, files:[{path,status,
  binary,truncated,lines:[{kind,text}]}]}`. New env vars `CAD_DIFF_MAX_FILES`
  (20) and `CAD_DIFF_MAX_LINES_PER_FILE` (400), read in `runtime.exs`; §12.6/§13.
- [x] 13 new tests (6 `Diff`, 4 `NodeDiff`, 3 router `/diff`). 137 tests total
  (89 shared + 48 daemon), green; format/`--warnings-as-errors` clean. No migration.
- [x] Phase 2a Slice B2b — colored diff in the Neovim hover panel: pure
  `cadence.nvim/lua/cadence/diff.lua` formatter (file headers, `+`/`-`/space
  prefixes, `…` markers, truncation/binary notes), per-line highlights
  (`CadenceDiffAdd/Delete/Header/Meta`), and `/diff` fetched on node change with
  a per-node cache injected from the plugin (`diff_fetcher`). `spec/diff_spec.lua`
  + an extended headless UI smoke (metadata + diff + union) pass.
- [x] Author display: kept a single committer identity (`created_by`) since the
  git author and node author are the same locally; no separate git-author field.

- [x] Phase 2a polish (Neovim): layer wrap + break marker in `graph.lua`
  (`max_cols` packs a wide layer into stacked sub-rows separated by a `╌` marker;
  default `nil` keeps the bounding-free horizontal-scroll rail), plus §6.3
  auto-open of the picker on `VimEnter` when cwd matches a registered project
  (`setup({ auto_open = false })` to disable). `graph.wrap_width` config added;
  new wrap tests + README/spec §6.2 notes.
- [x] Phase 2b **plan** scaffolded (no code): `docs/phase-2b-cloud-sync.md` — the
  cold-start brief for cloud sync (server scaffold, auth/tokens, object transfer,
  endpoints, daemon ledger/client, conflict handling, env, tests, 4 milestones,
  risks). New open decisions added to spec §16 (token issuance, cursor model,
  push batch/parent semantics).

- [x] Phase 2b-1 — server scaffold + Ash authentication. Added server deps
  (`phoenix`, `phoenix_pubsub`, `bandit`, `plug`, `ecto_sql`, `postgrex`,
  `ash`, `ash_postgres`, `ash_authentication`, `ash_authentication_phoenix`,
  `sourceror` dev/test). Added `Cadence.Server.Repo` (`AshPostgres.Repo`),
  `Endpoint`, `Application` supervision, `Router`, `AuthPlug`, `AuthController`,
  `TokenController`, `HealthController`, `SyncController`, and JSON helpers.
- [x] Ash accounts: `Cadence.Server.Accounts` domain + `User`, `Token`,
  `UserIdentity`, `ApiKey` resources. Humans use GitHub/Google OAuth; daemons
  use AshAuthentication API keys. `POST /auth/tokens` is OAuth-session-guarded
  and returns the plaintext key once; only the hash is stored.
- [x] Postgres migrations: `projects`/`nodes`/`memberships` (mirroring shared
  schemas), `parents uuid[]` + GIN index, server-only `nodes.seq bigserial` +
  index; Ash codegen accounts migration (`users`, `tokens`, `user_identities`,
  `api_keys`, `citext`/Ash functions).
- [x] Config: server runtime section (`CAD_PHX_HOST`, `CAD_PUBLIC_URL`,
  `CAD_HTTP_PORT`, `CAD_SECRET_KEY_BASE`, `CAD_TOKEN_SIGNING_SECRET`,
  `CAD_DATABASE_URL`, `CAD_DB_POOL_SIZE`, `CAD_OAUTH_*`); test Postgres via
  `CAD_TEST_DATABASE_URL` with ephemeral Docker; no secrets in source.
- [x] Server tests (15): account/key hashing, valid/revoked/expired API keys,
  OAuth registration action, `/health`, `/sync/me` 401/200 auth paths, token
  controller issuance, session guard, and a shared-schema Postgres round-trip
  (`Project`/`Node`/composite-key `Membership`).
- [x] 152 tests total (89 shared + 48 daemon + 15 server), all green.
  `mix format --check-formatted`, `mix compile --warnings-as-errors`, and
  `MIX_ENV=prod mix compile --warnings-as-errors` all clean.
- [x] Phase 2b-2 — object transfer + node push/pull. `Cadence.Shared.GitStore`
  gained `objects_from/2` (reachable commit/tree/blob walk, deduped),
  `import_objects/2` (SHA/type/payload validation, idempotent), `write_raw/3`,
  and `has_object?/2`; 8 new shared tests.
- [x] Server sync: `Cadence.Server.ProjectGit` (per-project bare stores under
  `CAD_GIT_STORE_PATH`), `Cadence.Server.Sync` (membership checks,
  single-project/parents-first/fail-fast batches, identity node IDs,
  idempotent retries, sibling support, `nodes.seq` cursor pulls, PubSub
  broadcast), and `POST`/`GET /sync/nodes` controller actions.
- [x] Protocol/config: `PullNodes` now carries `project_id`; server env adds
  `CAD_SYNC_PULL_LIMIT` (default 100); `CAD_GIT_STORE_PATH` is wired at runtime.
- [x] 24 server tests (9 new sync tests + prior auth/core tests) covering
  push→pull round-trip into a clean store with matching tree SHAs,
  idempotency, sibling DAGs, cursor pagination, viewer/non-member denial,
  unknown projects/cursors, mixed projects, unknown parents, conflicts,
  tampered objects, broadcast, and missing server objects.
- [x] 169 tests total (97 shared + 48 daemon + 24 server), all green.
  `mix format --check-formatted` and compile clean in dev/test/prod.
- [x] Docs updated: spec §10.2/§10.3/§10.6/§12.6/§16 and the Phase 2b plan.
  Push batch semantics resolved; project-provisioning gap recorded.
- [x] Added `docs/phase-2b-3-prep.md`: ledger schema options, worker shape,
  push/pull flows, `created_by` mapping, config, `Req.Test` testing, and
  acceptance for the next session.

- [x] Slice 1 audit/hardening (pre-2b-3): added `Cadence.Shared.UUID` (shared
      cast helper used by schemas/server sync/daemon contexts); `Project` now
      defaults/truncates/requires `created_at`; `Node.created_at` is required;
      `ProjectLocation.created_at` truncates to second precision.
- [x] `Projects.register_project/1` is transactional, rejects duplicate
      `work_dir` values, verifies `ProjectRegistry.start_project/1`, and cleans
      up rows if the project fails to boot. `rehydrate/0` logs per-project
      failures and only skips before migrations (no blanket rescue).
      `MessageQueue.rehydrate/0` has the same narrow pre-migration handling.
- [x] `CommitQueue` node insert + `Session.commit_after`/`spawn_after` are
      transactional; Git author comes from `CAD_GIT_AUTHOR_NAME`/
      `CAD_GIT_AUTHOR_EMAIL` via `Env.git_author/0` (no hardcoded author).
- [x] New `Cadence.Daemon.Nodes` (`latest/list/most_recent_by_user/preview`) and
      `Cadence.Daemon.NodeStore` (`open/read_commit/parent_tree`). Reused by
      `CommitQueue`, `Session`, `MessageQueue`, `NodeDiff`, and `API.Router`.
      `Session.anchor_node/1` now uses bounded queries instead of loading the
      entire project DAG on each commit.
- [x] Daemon API UUID hardening: malformed project/node IDs return 400/404
      instead of raising `Ecto.Query.CastError`.
- [x] `GitStore` hardening: object reads no longer create atoms from arbitrary
      file content, malformed/unknown/mismatched-size objects read as missing,
      `build_tree` tolerates files disappearing mid-snapshot, tree collection
      avoids quadratic list concatenation, and `diff_trees` raises a clear
      error for missing trees.
- [x] `Cadence.Shared.Diff` has a `CAD_DIFF_MAX_BYTES` guard so oversized files
      are marked truncated before Myers is run.
- [x] Added daemon migration `backfill_project_created_at` for projects created
      before the registration fix.
- [x] `config/runtime.exs` no longer requires `CAD_SECRET_KEY_BASE` outside
      prod; `.env.example` documents the missing daemon vars.
- [x] 17 new tests (shared UUID/malformed objects/diff guard; daemon Nodes/
      NodeStore/project registration/UUID rejection). 186 tests total
      (103 shared + 59 daemon + 24 server), all green. Format and
      `mix compile --warnings-as-errors` clean.

- [x] Slice 2 sync foundation: added `Cadence.Shared.Sync.NodeCodec` (shared
      node/flags/docs-state/timestamp/base64 object codec) with `Node.flags/0`
      and `Node.docs_states/0`. Server push decoding and pull encoding now use
      the shared codec; no wire-format change.
- [x] Daemon sync config in `Env` + `runtime.exs`: `CAD_SERVER_URL`,
      `CAD_AUTH_TOKEN`, `CAD_SYNC_ENABLED`, `CAD_SYNC_REQUEST_TIMEOUT_MS`,
      `CAD_SYNC_INTERVAL_MS`, `CAD_SYNC_RETRY_BACKOFF_MS`,
      `CAD_SYNC_MAX_ATTEMPTS`, `CAD_SYNC_PUSH_LIMIT`, plus injectable
      `sync_req_options/0` for `Req.Test` in Slice 3.
- [x] Daemon migration `create_sync_tables`: `sync_pending`, `sync_cursors`,
      `sync_state` (+ indexes) and a one-time seed of pre-sync local nodes into
      `sync_pending`.
- [x] `Cadence.Daemon.SyncLedger` (supervised GenServer + Repo): idempotent
      `enqueue/2`, parents-first `pending/1`, backoff-aware `due_pending/2`,
      `pending_projects/1`, `mark_pushed/1`, `mark_failed/3`, cursor
      round-trip, `server_user_id/0`, and forced/one-time `rehydrate/1`
      backfill. `SyncPending`, `SyncCursor`, and `SyncState` schemas added.
- [x] 13 new tests (4 shared codec; 8 ledger; 1 Env). 199 tests total
      (107 shared + 68 daemon + 24 server), all green. Format and
      `mix compile --warnings-as-errors` clean.

- [x] Slice 3 client + provisioning: `Cadence.Server.Projects.provision/2` and
      `POST /sync/projects` (idempotent by local project ID, first caller owner,
      owner/trusted repeat allowed, viewer forbidden, slug/foreign-owner
      conflicts). `Project.changeset` now maps the unique slug constraint.
- [x] `Cadence.Daemon.SyncClient` (`Req`): `configured?/0`, `me/0`, `push/1`,
      `pull/2`, `provision/1`; bearer auth, background request timeout, no
      internal retries, and injectable `sync_req_options/0` for `Req.Test`.
- [x] Server provisioning and daemon client tests: creation/idempotency,
      foreign user conflict, viewer rejection, slug conflict, malformed payload,
      auth requirement, bearer/header/body/query construction, HTTP and
      transport errors, and offline mode. No new dependency.
- [x] 13 new tests (6 server provisioning; 7 daemon client). 212 tests total
      (107 shared + 75 daemon + 30 server), all green. Format and
      `mix compile --warnings-as-errors` clean.

- [x] Slice 4 orchestration + integration: `Cadence.Daemon.Sync`
      (`ensure_server_user/0`, `ensure_project/1`, `push_pending/1`, `pull/2`,
      `sync/1`) with idempotent provisioning, parents-first push batches,
      `NodeCodec` payloads, mark-pushed/no-progress guards, object import +
      node insert + cursor advancement, and current-server-user `created_by`
      mapping. Pull conflicts abort before the cursor moves.
- [x] `Cadence.Daemon.SyncWorker` + `Cadence.Daemon.SyncTasks`: one scheduler,
      per-project network tasks, in-flight tracking, periodic and wake-on-
      enqueue passes. `Application` supervises both and performs boot
      `SyncLedger.rehydrate/0` + `wake_all/0` only when sync is enabled and
      configured.
- [x] `CommitQueue.do_commit/2` and `do_spawn/2` enqueue pending sync rows after
      the local transaction; `SyncLedger` wakes the worker only when sync is
      configured. Offline commits accumulate and flush later.
- [x] Error policy: 400/409/422 back off 24h, 401/403/404 back off 5m (404 also
      clears the provisioned marker), transient failures use exponential
      backoff capped at 1h (the max-attempts knob caps the exponent). Failed
      and conflicted rows are retained.
- [x] 9 new tests (7 sync integration incl. worker; 2 ledger). 221 tests total
      (107 shared + 84 daemon + 30 server), all green. Format and
      `mix compile --warnings-as-errors` clean.

- [x] Phase 2b-4 planning: added `docs/phase-2b-4-prep.md` with LWW preference
      versioning, partial-batch strategy, and the Phoenix Channels
      notification-only design. Chose `slipstream` as the daemon channel client
      (dependency lands in 2b-4d).
- [x] 2b-4a versioned preferences + server transport: `Membership`
      `preferences_updated_at` (nullable usec LWW version) + daemon/server
      migrations; `PushPreferences.updated_at` and
      `PullNodesResponse.preferences`; `POST /sync/preferences`; pull responses
      include the caller's preferences; accepted writes set `last_seen_at` and
      broadcast `{:preferences_updated, project_id, user_id}`; stale writes
      return current state without touching the row.
- [x] 7 new tests (1 shared membership; 6 server preference). 228 tests total
      (108 shared + 84 daemon + 36 server), all green. Format and
      `mix compile --warnings-as-errors` clean.
- [x] Committed 2b-4a as `25d6dfb`; added
      `docs/phase-2b-4b-prep.md` with the cold-start daemon-preference brief.
- [x] 2b-4b — daemon preference push/apply: added
      `Cadence.Daemon.SyncPreference` + `create_sync_preferences` migration;
      `SyncLedger` preference state/pushed/remote/error/wake helpers; `Session`
      switch/commit/spawn now bump `preferences_updated_at` monotonically and
      wake the worker; `SyncClient.pull` preserves preferences and
      `push_preferences/1` posts flat LWW payloads; `Sync.push_preferences`
      pushes only dirty versions and applies newer server responses; `Sync.pull`
      applies remote preferences after node import, filters unknown heads,
      preserves unknown pointers, and never echoes applied values.
- [x] Extended `TestSyncServer` with preference storage/LWW/pull support and
      added 16 daemon tests (session versions, ledger state, client transport,
      push/apply, pull filtering/older ignore, malformed payloads, e2e
      round-trip, offline flush, worker wake, existing-node filtering).
- [x] 2b-4b hardening: wake notifications are only emitted when sync is ready
      at enqueue/preference-change time (prevents stale wakeups); applied
      `active_heads` are deduplicated; malformed remote preference payloads are
      rejected; test teardown waits for in-flight sync tasks. 244 tests total
      (108 shared + 100 daemon + 36 server), all green; format and compile
      (dev/test/prod) clean.

- [x] 2b-4c — partial-batch node failure isolation: server wraps node-level
      parse/insert failures as `{:node_error, local_id, reason}` and controller
      responses include `failed_local_id` (batches remain atomic); daemon
      `SyncLedger.pushable/3` selects due nodes parents-first and blocks
      descendants of backed-off parents; `Sync` isolates the reported node,
      retries the rest, keeps descendants pending, and falls back to whole-batch
      failure for batch-level/unknown failures; ledger-write errors abort
      isolation to avoid retry loops.
- [x] Server + daemon tests for failed-ID error bodies, parent-first pushable
      selection, middle-node isolation, blocked descendants, retry-after-parent,
      whole-batch fallback, and out-of-batch failed IDs. 250 tests total
      (108 shared + 105 daemon + 37 server), all green; format and compile
      (dev/test/prod) clean.

- [x] 2b-4d — Phoenix Channels accelerator: server `UserSocket` +
      `SyncChannel` with `x-cadence-token` header auth, own-user-topic join, and
      `sync_available` forwarding; `Accounts.authenticate_api_key/1`; endpoint
      websocket declaration; `Sync` broadcasts after successful node pushes and
      accepted preference writes.
- [x] Daemon `SyncSocket` (`slipstream ~> 1.2`) with async connect, user-topic
      join, delayed join until `/sync/me` caches the server user, project-
      validated `SyncWorker.wake/1`, reconnect/rejoin defaults, and
      `CAD_SYNC_CHANNEL_ENABLED` + derived websocket URL config.
- [x] Real local websocket integration test via a test-only endpoint and
      test-only server `slipstream` dependency; channel/auth tests and no-
      broadcast-on-failure coverage. 264 tests total (108 shared + 113 daemon +
      43 server), all green; format and compile (dev/test/prod) clean.

- [x] 2b-4e — convergence + docs: added a two-machine preference journey
      (A pushes pointer/active heads → B applies → B moves the pointer → A
      converges) and an explicit socket-disabled polling fallback test. Updated
      the 2b-4/spec/progress docs and recorded the single-node PubSub
      limitation as an open decision. 266 tests total (108 shared + 115 daemon +
      43 server), all green; format and compile (dev/test/prod) clean.

- [x] Phase 3 docs preparation: added `docs/README.md` (doc index/read order)
      and `docs/phase-3-prep.md` (server gaps, proposed 3a–3e slices, dependency
      and security notes); corrected the stale docs tree in `AGENTS.md`; recorded
      the public-DAG-visibility and web-Y-axis contradictions in spec §16. No
      code or test-count changes (266 tests remain green).
- [x] Phase 3 decisions approved: public pages show the preview node only,
      authenticated members get the full DAG; depth-based web Y-axis; dead views
      first; `/p/:slug` routing; README-only docs; all projects public by
      default; review/promotion UI deferred to Phase 4. Updated spec §7.1/§7.2/
      §7.3/§13/§16 and added `docs/phase-3-roadmap.md`.
- [x] Phase 3a — UI foundation + read-only project page:
      `Cadence.Shared.GitStore.read_path/3` (slash paths, commit → tree → blob,
      1 MiB default cap, `:not_found`/`:not_a_file`/`:too_large`/`:unsafe_path`)
      with 6 tests; direct server deps `phoenix_html` + `phoenix_live_view`
      (dead views, no JS pipeline); `Cadence.ServerWeb` HTML helpers and
      `:controller` layout wiring; `Layouts` + `ErrorHTML`; HTML error rendering
      in the endpoint config.
- [x] `Cadence.Server.Portfolio` read context: `get_project_by_slug/1`,
      deterministic `list_nodes/1`, SQL preview resolution (pinned → functioning
      → newest), `membership_for/2`. Public `GET /` landing page and
      `GET /p/:slug` project page showing only the preview node; unknown projects
      return the HTML 404.
- [x] 21 new tests (6 GitStore, 10 Portfolio, 5 web). 287 tests total (114 shared
      + 115 daemon + 58 server), all green; `mix format --check-formatted`,
      `mix compile --warnings-as-errors`, and `MIX_ENV=prod mix compile
      --warnings-as-errors` clean.
- [x] Phase 3b design revised (no code): project home becomes a LiveView with a
      25/75 DAG + repository browser, nested node/tree/blob URLs, CSS lineage
      intro (root→default, pulse, repo reveal), hover tooltip-only, full public
      DAG with mandatory server-side secret filtering. Added
      `docs/phase-3b-prep.md`; updated spec §7.1/§7.2/§7.5/§7.6/§11/§12.6/§13/
      §16 and the Phase 3 roadmap. Awaiting approval before implementation.
- [x] Phase 3b-1 — LiveView project home + DAG + intro:
      `/live` socket, prebuilt `phoenix`/`phoenix_live_view` bundles served from
      dependency priv dirs, `app.js`, CSRF meta, and a shared layout for dead
      views + LiveView. Added `ProjectLive` with `/p/:slug` and
      `/p/:slug/n/:node_id`; removed the static project controller/view.
- [x] `Cadence.ServerWeb.DAGLayout` pure layout (depth layers, wrapping bands,
      elbow paths, preview/default resolution, lineage intro timing) and
      `Components.DAG` SVG (flag colors, pinned/selected rings, hover tooltip,
      patch links). CSS intro draw/pulse/repo-reveal with reduced-motion fallback.
      `CAD_DAG_INTRO_MS` (default 1200) and `CAD_LIVE_VIEW_SALT`.
- [x] `Cadence.Server.PublicContent` message redaction (provider tokens, AWS
      keys, private-key blocks, JWTs, generic assignments) applied to DAG
      tooltips and the node header before rendering. Full file/tree filtering +
      node quarantine begin in 3b-2.
- [x] `Cadence.Server.Portfolio.node_for_project/2`; `lazy_html` test-only dep for
      `Phoenix.LiveViewTest`.
- [x] 18 new tests (8 PublicContent, 6 DAGLayout, 4 ProjectLive + asset/404
      coverage). 305 tests total (114 shared + 115 daemon + 76 server), all
      green; `mix format --check-formatted`, `mix compile --warnings-as-errors`,
      and `MIX_ENV=prod mix compile --warnings-as-errors` clean.

## Next
- **3b-2 — repository browser + README + secret hardening.** Add
  `GitStore.list_path/4`, `Portfolio` snapshot reads, `MDEx`, file tree/file
  viewer/README, nested tree/blob routes, and extend `PublicContent` to path
  hiding, content redaction, binary suppression, commit-message redaction, and
  node-level quarantine.
- Add `CAD_FILE_MAX_BYTES`, `CAD_README_MAX_BYTES`, `CAD_TREE_MAX_ENTRIES` to
  runtime config and `.env.example`.
- Tests must prove no secret bytes reach anonymous HTML and that LiveView events
  cannot bypass filtering/quarantine.
- Open decisions: syntax highlighting (plain code for now), member raw-view
  policy, public `broken`/`sandbox` visibility.

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
  date/time + flag(s) + message + a color-coded diff (B2b).
- `GET /diff` is another new daemon endpoint (node vs. first parent) serving the
  line diff for the hover preview; documented in §13 Phase 2a. The line diff
  reuses the stdlib `List.myers_difference/2` rather than a new dependency.
- `GET /sync/me` is a temporary 2b-1 diagnostic route (bearer-key check). Real
  `/sync/nodes` routes landed in 2b-2; keep or remove `/sync/me` in a later
  cleanup once it is no longer useful for daemon setup checks.
- The server's Ash resources currently omit `Ash.Policy.Authorizer` (and its
  SAT-solver dependency); authorization is enforced by controllers. Recorded as
  an open decision in spec §16. Revisit before the web UI calls Ash actions
  directly.
- `ash_authentication_phoenix` pulls `phoenix_live_view` transitively. 2b-1
  defines no LiveView UI, but the dependency is now present ahead of Phase 3.
- Server tests require a Postgres test database; `CAD_TEST_DATABASE_URL` is a
  test-only override (default `ecto://postgres:postgres@localhost:55432/cadence_test`)
  and is intentionally not part of the deployment env contract.
- New server auth endpoints `/auth/tokens/new` (GET form) and `/auth/tokens`
  (POST issue) are additions beyond the original Phase 2b endpoint list; spec
  §7.4/§13 now document them.
- Node identity is now identity-mapped (`local_id == cloud_id`), overriding the
  original plan's server-assigned cloud IDs. Spec §10.2/§10.6 updated; retries
  are idempotent by construction.
- **Server-side project provisioning resolved in Slice 3.** `POST /sync/projects`
  is idempotent by local project ID; the first caller becomes owner and
  existing owner/trusted members can re-provision. Spec §10.2/§13/§16 updated.
- Sync payload size is still unbounded beyond `CAD_SYNC_PULL_LIMIT` node count.
  Object/body caps and Phase 7 negotiation remain.
- Spec §3.2/§6.1 updated: `:CadSwitch` may target any node in the project, not
  only active heads. The picker needs this; active heads remain the usual
  shortcuts.
- `Project.created_at` and `Node.created_at` are now required by their
  changesets; `Project`/`ProjectLocation` truncate to second precision because
  their schema fields are `:utc_datetime`. Pre-release DBs with existing rows
  are unaffected (rows already carry values; missing legacy values are filled
  on update).
- `CAD_GIT_AUTHOR_NAME`/`CAD_GIT_AUTHOR_EMAIL`, `CAD_WATCH_BACKEND`,
  `CAD_LOCAL_USER_ID`, `CAD_DIFF_MAX_BYTES`, and the existing `CAD_LLM_*`
  retry/rate knobs are now documented in §12.6 and `.env.example`.
- `Projects.rehydrate/0` and `MessageQueue.rehydrate/0` intentionally skip only
  the pre-migration "no such table" case (logged); all other DB errors
  propagate. This preserves test boot ordering without hiding real failures.
- Slice 2 placed the global server user ID and the one-time backfill marker in a
  `sync_state(key, value)` table instead of duplicating `server_user_id` on every
  `sync_cursors` row (the prep brief allowed either). Cursors remain
  per-project.
- Pre-sync local nodes are seeded into `sync_pending` by migration and can also
  be backfilled by `SyncLedger.rehydrate/1`; the marker makes the app-level pass
  idempotent. Pulled nodes are never enqueued for push.
- `NodeCodec` now returns string-keyed wire maps on encode (JSON output is
  unchanged) and decodes into atom-keyed changeset attrs. The server still owns
  its push-time validation and error taxonomy.
- `POST /sync/projects` is an addition beyond the original sync endpoint list
  (spec §10.2/§13 now document it). Project metadata is creation-only: repeat
  provisioning returns the existing project rather than overwriting the server
  row. `:project_conflict` (409) is distinct from node `:conflict`.
- `Project.changeset/2` now maps the unique slug constraint, so provisioning
  races return `:project_conflict` instead of a raw constraint error.

- Slice 4 added `Sync`/`SyncWorker`/`SyncTasks` and commit/spawn hooks. The
  worker uses `CAD_SYNC_MAX_ATTEMPTS` as a backoff-exponent cap, not a hard
  retry limit: transient failures retry indefinitely (capped at 1h) so offline
  commits eventually flush.
- Pulled nodes map only the current server user's `created_by` to the local
  user ID; other users keep their server UUID.
- `:CadOpen`'s short cloud-sync attempt is not wired to `Sync.sync/1` yet;
  deferred until 2b-4/picker polish.
- Provisioning is cached per project in `sync_state`; a 404 from push/pull
  clears the marker so the next cycle re-provisions.
- 2b-4a preference semantics: `preferences_updated_at` is nullable (nil means
  never synced), and only strictly newer writes are accepted. Stale pushes
  return 200 with the current server preferences rather than an error; the
  daemon compares the returned version and applies it when newer.
- `POST /sync/preferences` is a new endpoint beyond the earlier sync list; spec
  §10.5/§10.6/§13 now document it. The pull response carries `preferences`
  alongside nodes/cursor.
- The server still accepts preference node IDs without verifying they exist;
  the daemon filters unknown `active_heads` and ignores unknown pointers when
  applying remote preferences.
- `CAD_SYNC_CHANNEL_ENABLED` (default `true`) disables only the notification
  socket; sync/polling continue. The socket is also skipped when sync is
  disabled or credentials are absent.
- The server broadcasts `sync_available` only on the writer's `sync:user:<id>`
  topic; other project members converge through polling.
- `cadence_server` has a **test-only** `slipstream` dependency solely for the
  real local websocket integration test; production server code does not depend
  on it.
- `last_seen_at` is now set on accepted preference writes (previously unused).
- Pre-existing local preferences with a `nil` `preferences_updated_at` are not
  force-pushed until the next switch/commit/spawn. This follows the 2b-4b brief:
  assigning a version on first boot could clobber a newer value from another
  machine.
- Remote `session_pointer: nil` (or a pointer to a node absent locally) leaves
  the local pointer unchanged; unknown `active_heads` entries are dropped.
  Applied remote versions are marked pushed so they are not echoed. Spec §10.5
  now documents this.
- Preference push failures are diagnostic state in `sync_preferences.last_error`
  and retry on the next sync cycle; they never enter `sync_pending`. A
  preference failure does not block the node pull in `Sync.sync/1`.

- Node push errors now carry `failed_local_id` in the body for per-node failures;
  batches remain atomic (no partial inserts). Spec §10.6 documents the shape.
- The daemon selects push batches with `SyncLedger.pushable/3`: due nodes are
  sent parents-first, and children of a backed-off parent remain pending instead
  of being marked failed as out-of-order.
- The notification socket relies on local Phoenix PubSub: broadcasts do not
  fan out across multiple server nodes. Recorded in spec §16; polling remains
  the correctness fallback.
- Phase 3 public visibility changed after review: anonymous visitors now see the
  full read-only DAG and may browse any node's snapshot. This supersedes the
  earlier preview-only decision. Spec §7.1/§7.2/§7.5/§7.6/§16 updated.
- Phase 3b adds mandatory public secret filtering (path hiding + content
  redaction + commit-message redaction + binary suppression). It is best-effort,
  not a guarantee; per-project overrides and member raw-view policy remain open
  in spec §16. No content may be logged.
- Phase 3b serves the prebuilt `phoenix`/`phoenix_live_view` browser bundles from
  dependency priv directories plus a hand-written `app.js`; no Node build or
  `esbuild` dependency. This is noted in spec §11.
- New Phase 3b server env vars: `CAD_DAG_INTRO_MS` (1200),
  `CAD_FILE_MAX_BYTES` (524288), `CAD_README_MAX_BYTES` (262144), and
  `CAD_TREE_MAX_ENTRIES` (1000). `.env.example` must be updated during 3b-2.
- Syntax highlighting for the file viewer is still undecided; default 3b-2 is
  escaped plain code. Any highlighter must be added to spec §11 first and must
  operate on redacted content.
- LiveView project routes replaced the static `/p/:slug` controller route:
  `/p/:slug` and `/p/:slug/n/:node_id` are live in 3b-1. The tree/blob routes
  land with the 3b-2 repository browser. Unknown projects render a not-found
  page with HTTP 200 (LiveView mount cannot set a 404 after render); revisit if
  search-engine semantics matter.
- 3b-1 added a test-only `lazy_html` dependency (required by
  `Phoenix.LiveViewTest`) and `CAD_LIVE_VIEW_SALT` (defaults to
  `CAD_SECRET_KEY_BASE`). Both are documented in spec §11/§12.6.
- Found and fixed a real server-boot bug during a live smoke test: the endpoint
  had no adapter configured, so Phoenix defaulted to Cowboy2 (not a dependency).
  `config/config.exs` now sets `adapter: Bandit.PhoenixAdapter`; spec §12.3
  records it. The smoke test served `/p/:slug` and all four browser assets with
  200s.
- Public commit messages are redacted in 3b-1 via `Cadence.Server.PublicContent`.
  File/tree redaction and node-level quarantine are 3b-2; until then the repo
  pane is a metadata placeholder and exposes no file content.

- Phase 3a added `Cadence.Shared.GitStore.read_path/3` (commit-relative file
  reads with a 1 MiB default cap and path-traversal rejection). It is a read
  helper beyond the object operations enumerated in §5.2/§13; `Portfolio` and
  the README slice use it.
- Phase 3a added `GET /` (placeholder landing page) and `GET /p/:slug`
  (preview-only project page) on the browser pipeline. The 3c slice will turn
  `/` into the project index; the route already exists so the layout/header link
  is never dead.
- The server now declares `phoenix_html` and `phoenix_live_view` directly even
  though both were already present transitively. 3b starts using LiveView for the
  project home; 3a's dead-view page is superseded.
- `membership_for/2` is in place for the 3d authenticated controls.

## Last Updated
2026-10-24 — Phase 3b-1 complete: LiveView project home, full public SVG DAG,
lineage intro animation, hover tooltips, node selection via patch, and public
commit-message redaction. Also fixed the missing Bandit endpoint adapter found
during a live smoke test. 305 tests green (114 shared + 115 daemon + 76 server);
format and compile (dev/test/prod) clean. Next session starts 3b-2 (repository
browser + file/tree secret filtering + quarantine).
