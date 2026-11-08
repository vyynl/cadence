# Cadence — Progress

## Current Phase
**Phase 7 — storage engineering is complete (7a–7d).** The git build order in
spec §13 ends here. The next session picks up the carry-over list in **Next**
(open review suggestions, optional live smokes, §16 deltas).

## Done (summary)

- **Phase 1** — local daemon, watcher/commit queue, Unix-socket API, Neovim
  plugin, AI commit messages.
- **Phase 2a** — DAG API, Neovim DAG picker, hover diffs.
- **Phase 2b** — Phoenix server, AshAuthentication, object transfer, node
  push/pull, provisioning, sync ledger/worker, LWW preferences, notification
  channels, partial-batch isolation.
- **Phase 3** — LiveView project home, full public DAG, repository browser,
  MDEx README rendering, public secret filtering + node quarantine, portfolio
  index, canonical metadata, owner pin/unpin, member read panel, explicit
  owner/trusted raw view.
- **Phase 4a-1** — server-only `Proposal` + `Incident` schemas/migration,
  `Proposals` context (create/list/token/approve/reject, single approver,
  idempotent transitions), `Incidents` context (open/list/resolve, critical
  blocking checks), shared `Authorization` role helpers, and 21 focused tests.
- **Phase 4a-2** — public read-only `GET /proposals/:token`:
  `Cadence.Server.ProposalView` (first-parent file-level diff via capped
  `GitStore.walk_blobs/3`, sensitive-path filtering + `hidden_count`,
  content-secret quarantine, incident isolation), controller + HTML templates,
  real 404s for unknown token/missing project, no mutation routes, no
  identities, no raw toggle, token kept out of access logs. `Repo.quarantine/1`
  gained optional `eyebrow`/`title`/`body`. 33 new tests.
- **Phase 4b session A (P0 + P1)** — shared primitives: `GitStore.put_files/2`
  (in-memory path/content → tree), pure `Cadence.Shared.Meld` (deterministic
  union + conflict-only op application), `Cadence.Shared.LLM.Meld` +
  `priv/prompts/meld.txt` (`meld-v1`, strict parser, bounded prompt), and
  `LLM.provider/0`. Server infra: `result_metadata` jsonb migration, project-
  scoped incidents (+ partial unique index and dedupe), `LLMRateLimit`,
  supervised `MeldWorker` (timeout, bounded retry, injectable `:meld_llm`),
  `CAD_MELD_*` config, and `hammer` declared directly. 50 new tests.
- **4b session A review** — `PASS WITH WARNINGS`; all 4 findings fixed
  (see `.claude/plans/meld-worker-4b/reviews/meld-worker-4b-triage.md`):
  UTF-8 truncation crash guard, `build_prompt/3` now returns
  `{:ok, prompt} | {:error, :context_too_large}` instead of silently dropping
  conflicts, `put_files/2` rejects `.git` segments, `TestMeldLLM.setup/0`
  fixes ETS ownership.
- **4b session B (P2 + P3 + P4)** — `Cadence.Server.Melds.propose/3` ships the
  full pipeline: authorization, project-scoped parent loading, capped walks,
  deterministic union, conflict-only agent call, strict parse/apply, binary and
  Elixir-syntax guards, result tree/commit, pending proposal +
  `result_metadata`, and secret detection. Failure mapping: `meld_failed` /
  `agent_output_invalid` / `missing_objects` high, `scan_incomplete` and
  `secret_detected` critical; `:context_too_large` opens a critical
  `scan_incomplete` without calling the model. Spec §6.5/§6.7/§10.6/§11/§12.6
  updated. 19 new tests.
- **Phase 4b-2 (server push scan + node incidents)** — new
  `Cadence.Server.NodeScans` scans only newly inserted snapshots after the push
  transaction commits (best-effort, capped by `scan_max_files`/`scan_max_bytes`)
  and opens node-linked incidents: `secret_detected`/`scan_incomplete` critical,
  `missing_objects` high, clean → none. `Sync.push_nodes/2` keeps its response
  and scans before broadcasting; `Portfolio.quarantine_status/3` now checks an
  open critical node incident first and falls back to the read-time scan.
  Spec §6.7 records acknowledgment resolution for immutable snapshots. 18 new
  tests.
- **Phase 4c P0 (4c-1 approval backend)** — `Proposals` can now decide for
  real. New `result_integrity/2` (promotion → `:ok`; meld → `objects_from/2`
  succeeds and `read_commit/2`.tree == `result_tree_sha`; errors
  `:missing_objects | :tree_mismatch | :not_a_commit`; fails closed on a
  corrupt store instead of raising), `get/3` (member-scoped) and
  `result_node/1`. `decide/4` locks the **project** row then the proposal row
  (serializes duplicate-result approvals — no unique index exists), verifies
  integrity inside the transaction, rolls back with `{:integrity_failed,
  reason}` and then opens a critical `scan_incomplete` proposal incident
  (`stage: :approval_integrity`) outside it. Approval attaches/reuses the meld
  node by `(project_id, git_commit_sha)` (`parents = parent_ids`, flags
  `[:"in-progress"]`, `pinned: true`, `docs_state: :pending`,
  `created_by = proposer_id`, `"Meld of N sessions"`) or pins the promotion
  target; both refuse when an open critical **node** incident quarantines the
  node (`:blocked`). Broadcasts `{:proposal_decided, …}` plus
  `{:nodes_pushed, …}` for melds only, after commit; refused decisions are
  silent. 38 focused tests (+16 net over the slice).
- **Phase 4c P1 (4c-2 review hub)** — the member-only review surface:
  `ReviewLive.Index` (`/p/:slug/reviews`) lists every proposal pending-first
  with status/kind/age/parent count and links to both the review page and the
  public token page; `ReviewLive.Show` (`/p/:slug/reviews/:proposal_id`) renders
  the decision state, proposer/reviewer, parents or promotion target, the same
  file-level first-parent result as the public page, and an integrity notice.
  `ReviewAccess.authorize/2` is the single access rule (member with
  `can_view?/1`, else redirect to the public project page with a flash); it runs
  in `handle_params/3` because an `assign_async` failure cannot navigate, while
  `mount/3` stays DB-free and all proposal/result data loads with
  `assign_async/3`. Decide controls need `can_decide?/1` + `pending`;
  `handle_event` re-reads the membership before calling
  `Proposals.approve/reject` and maps `:blocked | :integrity_failed |
  :invalid_transition | :forbidden | :not_found` to flashes. Approve is hidden
  when the result is isolated, unverifiable, quarantined, too large, or
  unavailable (a blind approval is not offered); reject stays available.
  Parent commit messages are redacted (`PublicContent.redact_message/1`) and
  emails are shown only to the §7.2 manager audience, so viewers see display
  names. New `Authorization.can_manage?/1`. Router: both routes inside
  `ash_authentication_live_session`; `:browser` gained `plug(:fetch_flash)`
  (needed for a flash on a live redirect). 16 LiveView tests + 5 authorization
  tests.
- **Phase 4c P2 (4c-3 incident panel)** — `ReviewLive.Index` now loads
  `Incidents.list_open/2` with a second `assign_async` and renders an
  open-incident panel: severity, kind, title, age, proposal/node subject links,
  and a **closed whitelist** details summary (`patterns`, `sensitive_paths`,
  `reason` only — unknown keys are never rendered). Resolve/Acknowledge is
  shown only to `can_decide?`; `handle_event("resolve_incident", …)` re-reads
  the membership, refreshes `can_decide?`, and calls `Incidents.resolve/4`.
  `ProposalView.verify_resolution/1` is the `:verify` callback: proposal-linked
  melds re-scan under the §7.6 caps (`still_risky` on a secret/sensitive path,
  `unverifiable` when the walk fails) **and** re-assert the §6.6 tree invariant
  (`integrity_failed` while `result_tree_sha` mismatches, so integrity
  incidents cannot be dismissed); promotions and proposal-less incidents
  resolve by acknowledgment. `Incidents.resolve/4` now verifies **before** the
  `FOR UPDATE` transaction so a store walk never holds the row/pool connection;
  `list_open/2` caps at 50 (critical first, UI says when truncated). Flash
  mapping covers `integrity_failed` in addition to the plan's four errors, and
  unknown failures log only their shape. 14 new tests (12 LiveView + 2
  context) — 565 total. Spec §6.6/§6.7/§7.1/§7.2/§7.6/§13 updated; styling
  observations in `docs/ui-notes.md`.
- **Phase 4d-1 (convergence + pre-4d cleanup)** — approvals now reach daemons
  and pinned state converges. New `Cadence.Server.SyncNotifier` fans
  `{:sync_available, project_id}` out to **every project member's**
  `sync:user:<id>` topic (pushes, every decision, every real pin change);
  preference writes stay per-acting-user. `Proposals` emits
  `{:nodes_pushed, ...}` only when a node is actually created or its pin flips
  (promotions now included), and every committed decision fans out after
  commit. Pinning bumps `nodes.seq` **after** the pin commits
  (`Sync.touch_node/1`, raw parameterized SQL) so a concurrent pull cannot
  advance past an uncommitted token; the daemon applies **only** `pinned` to an
  existing pulled row (same id/sha/parents) and still treats anything else as a
  conflict. `result_integrity/3` is now capped by `Portfolio.scan_limits/0`
  (`:too_large`) and requires the first parent node/commit/tree to be walkable
  (`:missing_parent`), closing the two approval gaps; resolution re-runs the
  whole integrity check. Notification and cursor-bump failures are best-effort
  and logged by shape only. 13 new tests; 578 total. Review verdict PASS WITH
  WARNINGS; all 3 Mediums fixed (post-commit bump, parent-tree check, approval
  cursor test) plus the Lows.
- **Phase 4d-2 (union route)** — `POST /sync/union` (bearer PAT scope) takes
  `project_id` + `parent_node_ids` (2–8 distinct) and delegates to
  `Melds.propose/3` synchronously, returning `201 %{proposal_id,
  proposal_token, status, kind}` (no node is created). Errors: 403
  non-proposer, 404 unknown project, 422 invalid/too many parents or payload,
  429 + `Retry-After` on the per-project meld rate limit, 502 model/agent
  failure (with an incident), 500 for a server-side object corruption.
  `Melds.propose/3` now returns an existing pending meld for the same ordered
  parents (sequential queue dedupe; rejected work re-proposes), caps parents at
  8, and keys the LLM limiter per project. `UnionResponse` is the proposal
  reference. 8 request tests; 587 total.
- **Phase 4d-3 (daemon + Neovim trigger)** — `:CadUnion` now submits for real.
  `Env.sync_union_timeout_ms/0` (`CAD_SYNC_UNION_TIMEOUT_MS`, 180 s) covers the
  synchronous meld; `SyncClient.union/3` posts `/sync/union` and
  `Sync.propose_union/3` provisions first and best-effort pushes pending nodes
  so a just-committed parent is available. Daemon `POST /union` validates 2–8
  parents, returns `201 %{proposal_id, proposal_token, proposal_url, status,
  kind}`, maps 503 unconfigured/unreachable, 504 timeout, 422 payload/unknown
  synced-parent (friendly message), 429 rate limit, and passes server
  403/404/409/422/500/502 through. The Neovim picker keeps selection order
  (first parent = diff base), `<C-s>` is gated to union mode, and submission is
  **async** (`client.post_async`), so the editor never freezes; the token/URL
  arrives as a notification. Spec §6.1/§6.5/§10.6/§12.6 updated; 11 new daemon
  tests. Review verdict PASS WITH WARNINGS; H1 + six Mediums fixed (async
  submit, 503/504 mapping, ordered parents, push-before-union, timeout formula,
  passthrough tests, offline wording).
- **Demo stack (P0–P3)** — one `docker compose up` gives a browsable Cadence:
  `postgres:16-alpine` plus a `MIX_ENV=dev` server that migrates, seeds and
  boots only `cadence_server`. Compile-gated `password :demo` strategy
  (`CAD_DEMO_AUTH` read via `Application.compile_env`; registration disabled;
  prod build has no strategy and `mix`/releases refuse a mismatched runtime
  flag; `runtime.exs` raises as a second layer). `Accounts.User` gained
  `hashed_password` (sensitive) + an internal `:create` action and an
  ash.codegen migration/snapshot. `Cadence.Server.DemoSeed.run/1` +
  `mix cadence.demo_seed` build two projects (5-node `cadence-demo` with every
  flag, a pin and a critical node incident; `meld-review` with pending
  meld/promotion, an approved meld via `Proposals.approve/3`, a rejected meld
  and an isolated result), four accounts sharing `cadence-demo`, memberships,
  idempotency, `--reset`, and partial-run recovery. Seed task disables the
  endpoint so `docker compose exec … --reset` cannot fight the running server
  for port 4000. Seeding is serialized with a Postgres advisory lock; `reset!`
  runs in a transaction and revokes auth tokens with
  `AshAuthentication.user_to_subject/1` (subjects are `user?id=<uuid>`); the
  internal create action requires a bcrypt hash (`~r/^\$2[aby]\$/`); and a
  `(project_id, created_at)` proposals index backs the review-queue sort.
  Header nav (Portfolio, signed-in email, Sign in/out),
  `/sign-in` + `/sign-out` routes with the app layout, a member-only Reviews
  link on the project header, `code_reloader` in dev, `docs/demo.md`, and spec
  §7.4/§11/§12.4/§12.5/§12.6 updates. 15 new tests; compose smoke verified
  (`/health`, `/`, both projects, a proposal token, `/sign-in` all 200;
  anonymous reviews 302; demo sign-in establishes a session).
- **UI freshness pass, Session A (4e-1)** — review and project pages now react
  to project activity. `Incidents` broadcasts
  `{:incidents_changed, project_id, incident_id, proposal_id, node_id}` after a
  new insert or an open→resolved transition (ids only, post-commit,
  best-effort with shape-only logging); `Proposals.create/2` broadcasts
  `{:proposal_created, project_id, proposal_id}`. `ReviewLive.Index`
  subscribes after `connected?/1` in `handle_params` (guarded by a
  `subscribed_project_id` assign), reloads proposals on
  created/decided and incidents on any incident event, and refreshes
  `can_decide?`. `ReviewLive.Show` reacts only to its own decision and to
  incidents that touch it — a proposal-linked incident, or one on the node the
  decision would promote/attach (`Proposals.decision_node/1`, mirroring the
  context's `ensure_node_approvable/2`), so a quarantined promotion target hides
  Approve live instead of failing on click; unrelated node incidents are
  ignored, and both roles are refreshed before every reload. `ProjectLive`
  keeps a quarantine cache keyed on both inputs — the node id (the snapshot
  scan is immutable) and the node's open-critical-incident flag (cheap to
  re-read) — so tree/blob patches reuse the scan while an incident change
  always re-derives; it subscribes incident-only and reloads the pane only when
  the event targets the selected node. Incident resolution derives the
  transition inside the `FOR UPDATE` transaction, so concurrent resolves cannot
  double-broadcast. Spec §6.6/§6.7/§7.2 updated. 26 new tests.
- **UI styling pass, Session B (4e-2)** — `Cadence.ServerWeb.Presentation` is
  the single source for `kind_title/1`, `format_flags/2`, `format_time/1`,
  `age/1`, and composite `status_badge_class/1` / `severity_badge_class/1` /
  `file_status_class/1` strings (15 tests); ProjectLive, both review LiveViews,
  ProposalHTML, and DAG call it with no rendered-text change. New
  `Components.Incident` owns the open-incident panel: **above** the queue,
  `aria-live` count plus a critical count, a severity badge and left accent (the
  severity word stays visible, so color is never the only signal), a closed
  `<dl>` whitelist rendering the **full** wrapped reason, and distinct
  Resolve (`button-primary`) / Acknowledge (`button-warning`) controls with
  inline hints; the trailing paragraph is gone. CSS gained semantic
  severity/status aliases over the existing palette (dark follows through
  `var()`, no new hues), `.badge`/`.status-*`/`.severity-*`, incident row
  accents, callouts, button modifiers, review-queue layout, and file-status
  colors. The public proposal page (status/file classes + read-only callout),
  the protected quarantine callout, and the portfolio node-count badge and
  monospace slug share the same vocabulary; multi-flag node badges stay neutral
  because a node can carry several flags. Spec §13 records 4e and §16 resolves
  review/promotion placement; `docs/ui-notes.md` moved its observations to
  Done. 17 new tests.
- **4e styling review → triage fixes** — W1: light-mode `--*-text` tokens
  (`#a40e26` 7.54/6.24:1, `#7d4e00` 6.79/6.13:1, `#116329` 7.08:1) now color
  status/severity/file/button text while the hue tokens stay on borders, tints,
  row accents, and the severity marker (dark aliases the existing hues, no
  visual change). S1: the DAG's pinned/flagless normalization is pinned by a
  component render test (tooltip and `aria-label` read `pinned`; previously
  `no flags · pinned`). S2: `Components.Incident` links use `~p` verified
  routes. S3: the `aria-live` summary now includes the critical-count line, and
  the styling test asserts containment (`has_element?`) rather than document
  order. S4: `docs/README.md` marks 4e complete. 1 new test.
- **Phase 5a (doc automation shared primitives)** — `.caddocs.yaml` schema
  parse/validation, pure glob matching, trigger gating (`generated_from`,
  schema change, API-surface heuristic), docs prompt + strict MODIFY/CREATE
  parser with read-only-path protection, `Cadence.Shared.UTF8`, and a
  path-directed `GitStore.merge_files/3`. Adds `yaml_elixir` directly and
  records §9.1/§9.3/§9.4/§9.5, §11, §12.6, and §16. Review verdict PASS WITH
  WARNINGS; all 5 findings fixed (read-only doc writes, binary diff guard, NUL
  paths, path-directed merge, `apply_ops` validation). 248 shared + 125 daemon
  tests green; server suite not rerun.
- **Phase 5b (daemon doc worker + commit integration)** — `SchemaSource` reads
  `.caddocs.yaml` from the working tree and best-effort caches it on
  `Project.docs_schema` (registration and schema-file commits). `CommitQueue`
  evaluates `Docs.Trigger`, sets `docs_state` (`:skipped` / `:pending`), records
  `session_metadata["code_commit_sha"]` only for queued jobs, and hands the sync
  enqueue to `DocQueue` instead of the ledger. `DocQueue` runs the job through
  `DocAgentWorker` (Task.Supervisor, Hammer `:docs`, injectable `:docs_llm`,
  bounded timeout), writes `C2` as a git child of `C1` with
  `GitStore.merge_files/3`, updates the node to `:current` (or defers with a
  shape-only error after `CAD_DOCS_RETRY_ATTEMPTS`), and is the only sync
  enqueue point for doc nodes. Working-tree writes are schema-scoped,
  watcher-suspended, and skipped when the user diverged from `C1`
  (`workdir_skipped`). `Watcher` gained registry-scoped `suspend/resume`
  (resume re-arms a pending debounce, and watcher commits now pass
  `skip_unchanged: true`, so a late poll/inotify event cannot create an empty
  node). `SyncLedger` holds doc-pending nodes out of
  `enqueue`/`backfill`/`pushable`; `DocDiff.build/2` exposes the schema-filtered
  `C1→C2` diff with a first-parent fallback. Reconnect/manual
  `DocQueue.retry_pending/0` re-gates deferred nodes and retries; boot
  `rehydrate/0` resumes them before the first sync pass. 36 new daemon tests
  (766 green: 251 shared + 161 daemon + 354 server at the time of writing).
  Review verdict REQUIRES CHANGES (B1 parents-first push); all 15 findings were
  fixed via `reviews/phase-5-docs-5b-triage.md`: every commit now carries a
  sync row (written in the node transaction) and only *selection* is gated
  (children cannot overtake a held parent), `mark_pushed/1` stamps a top-level
  `docs_pushed_sha` so a pushed node (including `:skipped` nodes) is never
  regenerated, a raising job is rescued, an empty generation writes no `C2`
  and a forced no-op keeps an existing one, `CAD_DOCS_MAX_FILES` is in §12.6,
  `retry_pending/1` is project-scoped, `:force` sync works on code-only nodes,
  worktree writes reject symlinks, `docs_enabled?` releases queued nodes, and
  the tests use a barrier/queue drain/`:fs_poll` instead of timing races.
- **Phase 5c (daemon doc API + Neovim commands)** — `DocQueue.sync/2` is a
  synchronous manual-sync decision point (project/node/anchor, pushed guard,
  `CAD_DOCS_ENABLED`, schema parse, LLM configured) that then casts
  `force: true`; `POST /docs/sync` maps it to `202 queued` (with `node_id`),
  `200 skipped` (`already_synced | disabled | no_schema | invalid_schema`),
  `503` unconfigured, `404`, `422`. `GET /docs/diff` maps `DocDiff.build/2` to
  `200` / `404` (node or commit) / `409` (no docs commit or no schema) / `400`;
  both endpoints default `node_id` to `Session.anchor_node/1` and
  `DocDiff.build/2` accepts `nil`. Neovim gained a pure `cadence.doc` helper
  (response→notification mapping + `diff.lua`-based formatting):
  `:CadDocSync [node_id]` posts asynchronously, and `:CadDocDiff [node_id]`
  opens a scratch split (`C1 → C2` header) or warns when there is no docs
  commit. Manual sync now respects `CAD_DOCS_ENABLED` (spec §9.2), and a
  pushed node reports `already_synced` until P4-T2. 9 new router tests, a new
  `cadence.nvim/spec/doc_spec.lua`; all Lua files pass `luac -p`. Spec
  §9.2/§9.4/§9.5/§12.6/§13 updated.
- **Phase 5 P4-T1 (reconnect docs retry)** — the deferred-docs retry now runs
  **before** the reconnect pass pushes. `Sync.sync/2` accepts `retry_docs:` and
  calls `DocQueue.retry_pending/1` between `ensure_project/1` and
  `push_pending/1`, so the hold is re-armed synchronously and the server
  receives one node at `C2`; `SyncWorker.start_project/2` requests it only on
  the first pass after boot or a failed pass (the post-pass hook in `finish/3`
  is gone), so a permanently failing job is retried once per outage and the
  node still syncs code-only. The old order could never work: a deferred node
  is pushable, so `C1` was pushed and stamped immutable before the retry could
  run. New `apps/cadence_daemon/test/doc_reconnect_test.exs` proves one pushed
  node at `C2` (never `C1`, `parent == [C1]`) and the failed-retry code-only
  fallback. Spec §9.5 updated; 182 daemon tests green (180 + 2).
- **Phase 5 P4-T2 (already-pushed docs child node)** — a node whose SHA is on
  the server is never rewritten; its docs attach as a follow-up child node.
  `docs_mode/1` replaces the old pushed guards with `:child` (any
  `docs_pushed_sha` stamp), `:local` (`SyncPending` row, no stamp) and `:legacy`
  (neither: pulled/pre-5b, refused), so `already_synced` is gone from
  `POST /docs/sync` and a pushed node queues normally. The child is
  `git_commit_sha: C2` (git parent `C1`), `parents: [code_node.id]`,
  `docs_state: :current`, `flags: [:"in-progress"]`, `pinned: false`,
  `metadata["docs"]["docs_for"]`, with its own `SyncPending` row
  (`SyncLedger.insert_pending!/1`, shared with `CommitQueue`) and session-pointer
  move in the same transaction; the parent keeps its SHA and records
  `docs_state: :current`, `docs_commit_sha: C2`, `docs_child_id`, so
  `:CadDocDiff` works on both nodes. An empty generation creates no child,
  `existing_child/1` makes repeats idempotent, `resumable_nodes/1` resumes
  stamped deferred nodes, and pushed nodes are never re-held or re-queued for
  sync. Review found one BLOCKER (the in-place SHA write was a check-then-write
  against the sync worker's stamp) and three warnings; all fixed: the write is
  now a compare-and-swap on `json_extract(session_metadata,
  '$.docs_pushed_sha')` with one re-read, `Session.docs_after/3` is a single
  conditional update, a pushed node with docs disabled keeps its deferred state,
  and the watcher stays suspended across the node write. Spec §9.2/§9.5
  updated. 6 new daemon cases (3 rewritten); 793 tests green (251 shared + 188
  daemon + 354 server).
- **Phase 5 P4-T3 (read-only docs badge)** — `Presentation.docs_state_label/1`
  and `docs_badge_class/1` (docs current/pending/skipped, reusing the AA status
  text tokens). `Portfolio.docs_child/2` finds the newest docs child only when
  both `metadata["docs"]["docs_for"]` **and** DAG parentage agree, scoped to the
  project (metadata-only claims are ignored; malformed/nil input returns `nil`).
  `ProjectLive` renders the selected node's own badge plus a `patch` link to the
  docs child (title: "Open the follow-up node carrying this snapshot's docs"),
  and `{:nodes_pushed, …}` re-reads **only** that link — the DAG layout is not
  rebuilt, so no intro replay. CSS gains `.docs-badge` hover/focus underlines.
  Spec §9.4 records the parent/child rendering rule. Review verdict PASS WITH
  WARNINGS; W2/S1–S4 fixed live (query-based child lookup, parentage check,
  event refresh, neutral tooltip, link-class assertions, hover affordance); W1
  (meld nodes stay `:pending`) recorded in §9.4/§16. 11 new tests; 804 total.
- **Phase 5 P4-T4/T5 (spec/README closeout)** — spec §9.3 records the child
  fallback in the commit model; §9.5 states the one-node-at-`C2` condition
  precisely; §9.6 documents the shipped worker (Task.Supervisor, Hammer
  `:docs`, timeout/retry/backoff, terminal errors, prompt versioning, caps);
  §13 carries the 5a/5b/5c/P4 breakdown; §16 keeps the deferred web review and
  adds the server-created-meld-node docs gap. `docs/README.md` marks Phase 5
  code-complete with P5 pending and stops calling `phase-4-prep.md` the current
  brief.
- **Phase 6a (Docker action manifest foundation)** — `Cadence.Server.Actions.Manifest`
  strictly parses `actions/manifest.json` (≤ 20 actions, ≤ 32 KiB, name
  `^[a-z0-9][a-z0-9_-]{0,63}$`, commands 1–512 bytes, descriptions ≤ 200 bytes,
  control/bidi chars and duplicates rejected, unknown keys ignored).
  `Cadence.Server.Actions` is snapshot-addressed (`GitStore.read_path` from the
  selected node), scopes the membership to the project, gates on
  `CAD_ACTIONS_ENABLED`, and maps every failure to a shape-only error.
  `ProjectLive` shows a read-only Actions panel to members (hidden for
  anonymous/non-members, disabled deployments, absent/invalid manifests, and
  quarantined snapshots), and re-derives it when quarantine flips or raw view
  toggles. Config: `CAD_ACTIONS_ENABLED`, `CAD_DOCKER_SOCKET`,
  `CAD_ARTIFACT_PATH`, `CAD_ACTIONS_MAX_MANIFEST_BYTES`,
  `CAD_ACTIONS_MAX_ACTIONS`. Spec §7.1/§7.2/§8.2/§12.5/§12.6/§13/§16 updated;
  `docs/phase-6-prep.md` records the phase plan. Review verdict PASS WITH
  WARNINGS; all five warnings and the actionable suggestions fixed
  (project-scoped membership, live panel refresh, fail-closed reads,
  whitespace/bidi validation, a11y/overflow, spec corrections). 40 new tests;
  844 total.
- **Phase 6b (Docker action runner)** — durable `action_runs` schema/migration
  and `Actions.Runs` (`prepare`/`start`/`execute`/`list`/`get`/`log`/`artifacts`/
  `recover_stale`/`recover_all`). Run boundary re-checks `can_manage?`,
  project/node membership, and an open critical node incident; staging walks the
  snapshot once (`Portfolio.scan_limits/0`), scans it for secrets **before**
  writing, then materializes `<run_id>/code`. Image policy:
  `Project.docker_image` wins, else root `Dockerfile` → cached
  `cadence-action-<slug>-<sha12>`, else `no_image`. Container: `Entrypoint
  ["/bin/sh","-c"]`, no network by default, memory/swap/CPU/PID limits,
  read-only rootfs + noexec `/tmp`, `CapDrop=ALL`, `no-new-privileges`, cgroup
  log cap (`1m`/1 file), code mounted read-only from a volume subpath and `/out`
  writable (0777, so non-root images work). Logs are tail-capped and written to
  `<artifact_path>/<run_id>/output.log`; artifacts go to
  `<run_id>/artifacts/` (regular files only, inode-bound bounded reads, 1,000
  files / `CAD_ACTIONS_MAX_ARTIFACT_BYTES`). Terminal writes precede container
  removal; confirmed removals clear `container_id`, failed ones are retried by
  the terminal-status orphan sweep. Heartbeats keep long builds from being
  recovered; `recover_stale` CASes per row (reads never touch Docker) and
  broadcasts only real transitions. `Actions.Docker` behaviour +
  `DockerEngine` (`ex_docker_api` 1.55, API default `v1.45`) with pure
  request/response helpers and unit tests; tests inject `FakeDocker`. Demo
  compose gained the socket proxy (method/resource allowlist) plus pinned
  `cadence-demo-actions`/`-artifacts` volumes. Config: `CAD_ACTIONS_*`
  (volume/path, timeouts, CPU/memory/PID, network + build network, log/artifact
  caps), `CAD_DOCKER_API_VERSION`; Elixir floor bumped to `~> 1.20`. Spec
  §8.2–§8.4/§11/§12.4/§12.6/§12.9/§13/§16 and `.env.example` updated. 53 new
  tests; 898 total (252 shared + 188 daemon + 458 server). Two review cycles:
  REQUIRES CHANGES (2 blockers: `start` mapped `%ErrorResponse{}` to `:ok`, and
  the image `ENTRYPOINT` was not overridden) → PASS. Lesson:
  `.claude/solutions/docker/ex_docker_api-false-success-20261106.md`.
- **Phase 6c (web run experience)** — manager-only Run controls on the node
  action panel, member-only `RunLive.Index` (`/p/:slug/runs`) and `RunLive.Show`
  (`/p/:slug/runs/:run_id`), and allowlisted artifact downloads
  (`RunArtifactController`). `handle_event("run_action")` re-reads the
  membership, reuses the rendered quarantine answer in normal view and
  re-derives it in raw view, checks `CAD_ACTIONS_ENABLED`, then calls
  `Runs.start/4` and navigates; stale recovery moved **inside** the spawned task
  so a click never blocks on the Docker proxy. Both LiveViews authorize in
  `handle_params`, load with `assign_async`, subscribe only after
  `connected?/1`, and refresh on `{:action_run_updated, …}` (the detail page
  only for its own run) with catch-all handlers. `Runs.list/get` are gated by
  the enabled flag; disabled deployments hide the nav link and redirect run
  pages. Output is rendered in an escaped `<pre>` after
  `Presentation.terminal_text/1` strips ANSI/OSC, C0/C1 controls, and bidi
  overrides and replaces invalid UTF-8 (never `raw/1`); logs are post-exit, so
  the page follows status live and output at the end. `Runs.read_artifact/2`
  accepts only an exact recorded path on a regular file; downloads are
  `application/octet-stream`, `attachment`, `private, no-store`, and every
  refusal is 404. New Presentation helpers (run status/error/duration);
  `.run-*`/artifact CSS over existing tokens. `expose` resolved as
  parsed-but-unhonored (members-only). Spec §7.2/§8.2/§8.3/§8.4/§13/§16,
  `docs/phase-6-prep.md`, `docs/README.md`, `docs/ui-notes.md` updated. 32 new
  tests; 940 total (252 shared + 188 daemon + 500 server). Independent review
  PASS WITH WARNINGS; the one Medium regression (a second snapshot scan on
  every Run click) was fixed by reusing the rendered answer outside raw view,
  plus the Lows. Lesson:
  `.claude/solutions/phoenix-issues/assign-async-key-and-controller-wildcard-list-20261107.md`.
- **High-severity `GitStore.walk_blobs/3` truncation fix** — `walk_tree_blobs/8`
  returned a 2-tuple from recursive subtree calls while the parent reduce
  expected `{:ok, acc, count, bytes}`; the catch-all halted the walk, so every
  sibling file after the first directory was skipped. Secret scans therefore
  missed root files in common repos (a directory sorts before `config.txt`).
  The recursion now threads one shape and `walk_blobs/3` sorts once at the top.
  Regression tests: `git_store_test.exs` (directory first, then files) and the
  project-page quarantine test (manifest + token). Consequence: scans are
  stricter; new pushes may open incidents for previously missed content, and
  over-cap parents now fail approval instead of silently passing truncated.
  Lesson: `.claude/solutions/data-integrity/walk-blobs-truncation-20261106.md`.
- **Phase 7a (shared pack layer)** — `GitStore.Pack` writes and reads Git pack
  v2 + idx v2 (SHA-1, zlib, ofs/ref deltas, 64-bit offsets, both checksums),
  `GitStore.Pack.Delta` (bounded block-matcher build + bounded apply), and
  `GitStore.Pack.Index`. `GitStore` reads loose-first then packs;
  `has_object?/2` consults indexes; `pack_objects/3` validates/dedupes, writes
  `.tmp` files, fsyncs, verifies every object by reading through the pack, then
  renames; `read_raw/2` and `present_shas/2` prepare 7b/7c. `GitStore.Cache`
  (with `Cadence.Shared.Application`) caches offsets and precomputed entry ends,
  invalidates explicitly, reloads once on a packed read miss, and validates each
  pack trailer against its index. Pack reads cap declared sizes and stream
  inflate; delta chains are capped; non-hex SHAs never probe paths. 54 new
  shared tests; 994 total (306 shared + 188 daemon + 500 server). Two review
  cycles: O(N²) entry ends, missing fsync, unbounded cache, temp-idx discovery,
  missing caps/hex guard/bulk+raw APIs, duplicate SHAs; then out-of-process
  cache misses, inflate drain, and directory-fsync durability (deferred loose
  deletion recorded for 7b). Spec §11/§13/§16, `docs/phase-7-prep.md`, and
  `docs/README.md` updated. Lesson:
  `.claude/solutions/data-integrity/pack-v2-byte-format-20261107.md`.
- **Phase 7b (server repacker)** — `Cadence.Server.Storage` + `Storage.Repacker`
  (plus `Storage.TaskSupervisor`) repack a project's loose objects without
  changing any read path. A run is: `GitStore.invalidate_cache/1` once → remove
  crash-left `tmp-*` pairs and half-completed `pack-*.pack`/`.idx` renames older
  than a 5 min grace → for every loose object covered by a usable pack, re-read
  it **through the pack** and re-hash (`GitStore.verify_packed/2`, new) and only
  then unlink (failures counted/logged) → pack the remaining loose objects in
  `CAD_REPACK_MAX_PACK_BYTES` batches, reading **loose files only** and
  re-hashing them (`GitStore.read_loose_raw/2`, new). The writing phase never
  deletes (OTP cannot fsync a directory); the next threshold run or the 6 h
  backstop performs the verified sweep. Threshold counts on-disk loose
  objects/bytes (so a pack run is followed by its sweep); one run per project
  via an in-process FIFO queue plus a transaction-scoped
  `pg_try_advisory_xact_lock(hashtext('cadence.repack'), hashtext(project_id))`
  (a `:busy` result is skipped, never a failure, and keeps any existing
  cooldown). `Sync.push_nodes/2` calls `Storage.maybe_repack/1` after the push
  commits (best-effort, async); `mix cadence.repack [--project <id|slug>]` runs
  unconditionally and prints stats/outcome. Failure cooldown = one
  `CAD_REPACK_INTERVAL_MS`; the backstop bypasses it. Config:
  `CAD_REPACK_ENABLED`, `CAD_REPACK_MIN_OBJECTS` (1000), `CAD_REPACK_MIN_BYTES`
  (64 MiB), `CAD_REPACK_INTERVAL_MS` (6 h, `0` disables backstop+cooldown),
  `CAD_REPACK_MAX_PACK_BYTES` (64 MiB). Spec §12.6/§13/§16,
  `docs/phase-7-prep.md`, `docs/README.md`, `.env.example` updated. 29 new tests
  (storage/repacker/git store) + a push-wiring case; 1023 total (309 shared +
  188 daemon + 526 server). Two read-only review cycles: PASS WITH WARNINGS,
  then the second pass found 3 new warnings, all fixed (empty-batch packer call,
  orphan-sweep grace for in-flight renames, content re-hash on loose reads).
  Lesson:
  `.claude/solutions/data-integrity/repack-deferred-deletion-20261107.md`.
- **Phase 7c (sync existence handshake)** — `POST /sync/objects/exists`
  (bearer PAT, `owner`/`trusted`, project-scoped) takes
  `%{project_id, shas: [40-hex]}` and answers `%{present: [...]}` from
  `GitStore.present_shas/2` (loose files + pack indexes in one pass). Invalid
  SHAs are refused; the raw list is capped before dedupe by
  `CAD_SYNC_EXISTS_LIMIT` (5000). `Cadence.Shared.Sync.ObjectsExists` is the
  shared request struct; `SyncClient.objects_exist/2` is the daemon call.
  `Sync.push_batch/3` now loads each node's `objects_from/2` once, collects the
  batch's unique SHAs, chunks them under the same cap (a non-positive cap
  disables the handshake), unions the answers, and filters each node's
  `git_objects` before encoding. Any failed chunk sends the whole batch
  unfiltered; a 422 on a filtered push retries once with every object and then
  surfaces the normal node error. Metadata is always sent; `ensure_complete/2`
  remains the authority. Tests: 9 server cases (+ acceptance for an existing
  commit with no objects and a genuinely missing commit) and 7 daemon cases
  (drop, per-object filter, chunking, non-positive cap, failure fallback, 5xx
  no-retry, full-object retry); `TestSyncServer` gained the existence route and
  present-set/push-call counters. 10 new tests; 1042 total (309 shared + 198
  daemon + 535 server). Spec §10.2/§10.6/§12.6/§13, `docs/phase-7-prep.md`,
  `docs/README.md`, `.env.example` updated. Two review passes: no blocker/high;
  fixed the cap-skip design (now chunked), a `<= 0` chunk-size footgun, raw-cap
  ordering, daemon config docs, and stronger tests. Lesson:
  `.claude/solutions/data-integrity/sync-existence-chunking-20261107.md`.
- **Phase 7d (verification/closeout)** — the remaining 7d claims are pinned by
  tests: `git_store_test.exs` reads across two packs plus a loose object after
  `invalidate_cache/1` between writes (`read_blob/read_commit/read_tree/
  read_path/walk_blobs/objects_from/diff_trees/has_object?`); `pack_index_test.exs`
  covers all 256 fanout buckets and grows the zero bucket by 64 entries;
  `pack_test.exs` pins the delta-depth boundary (a 50-delta chain reads at
  `max_depth: 50` and fails at 49); `storage_repacker_test.exs` proves a run
  after a sweep packs only new loose objects and leaves the existing pack bytes
  untouched. Demo-stack smoke: run 1 packed 29 + 36 loose objects into one pack
  per project, run 2 swept 29 + 36 verified loose copies, run 3 was a no-op;
  `Storage.stats/1` reported `loose=0`, `packed=29/36`, `packs=1`; a fresh VM
  and the live server both read the same commits/trees/blobs from packs, and
  `/`, both project pages, `/sign-in`, and all five seeded proposal pages
  returned 200 with rendered diff paths. Spec §13 Phase 7, `docs/README.md`, and
  `docs/phase-7-prep.md` closed. 1046 tests green (312 shared + 198 daemon + 536
  server); format and dev/prod compile clean.
- **Post-7d freshness follow-ups** — both open review suggestions are fixed.
  `Portfolio.quarantine_status_with_source/3` now distinguishes a completed scan
  (`{:ok, :ok | :quarantined}`) from a failed walk (`{:error, :unverifiable}`);
  `quarantine_status/3` keeps its old `:ok | :quarantined` contract. `ProjectLive`
  gained `quarantine_cacheable?`: it reuses an answer only when it was
  authoritative, so a same-key incident event retries a failure-derived
  quarantine (regression test lowers `scan_max_files` to 0, restores it, opens a
  high non-blocking incident, and expects the pane to recover; it fails against
  the old cache). `ReviewLive.Show.incident_relevant?/5` treats any incident as
  relevant before the first successful payload load, forcing one reload so a
  decision-node incident that arrives mid-load cannot be dropped; the pure
  predicate has a unit test. 3 new tests; 1049 total (312 shared + 198 daemon +
  539 server). Format and dev/prod compile clean. Residual: a Run click still
  reuses the rendered answer, so an owner needs an event/navigation to run
  against a snapshot whose previous scan failed (staging remains the authority
  and the refusal is fail-closed).
- **4e gate:** 640 tests green (161 shared + 125 daemon + 354 server);
  `mix format --check-formatted`, `mix compile --warnings-as-errors`, and
  `MIX_ENV=prod mix compile --warnings-as-errors` clean; prod build reports
  `AshAuthentication.Info.strategy(User, :demo) == :error`.
- **Tooling (OpenCode)** — vendored skill checkout + restore script
  (`scripts/setup-opencode.sh`, 51 skills), project `opencode.jsonc` (mix
  formatter, destructive-command guards), AGENTS.md §12 (routing, Iron Laws,
  state/artifact mapping), `docs/opencode.md`.
- Full session-by-session history is frozen in
  `docs/archive/progress-history.md`.

## Next

**Immediate step:** run the **union live smoke** — the one shipped trigger
surface with no live run. `docker compose up --build -d`, start the daemon
against the demo server, select two nodes in Neovim, run `:CadUnion`, and
confirm the proposal token/URL notification plus the review page. Record the
result in this file. This exercises `POST /union` → `POST /sync/union` →
`Melds.propose/3` end to end; the plan is in `docs/demo.md`.

**Integration contract (6c, for anything that touches runs):**
`Actions.Runs.prepare/4` returns `{:ok, %ActionRun{}}` or
`{:error, :disabled | :forbidden | :not_found | :quarantined | :unknown_action |
Ecto.Changeset.t()}`; `start/4` adds the async task and returns the queued row;
`execute/1` is the synchronous body tests use. Statuses are
`queued → running → succeeded | failed | timed_out | interrupted`; infra
failures carry a closed `error_reason` (`quarantined`, `staging_failed`,
`no_image`, `build_failed`, `create_failed`, `docker_unavailable`,
`run_failed`). `log_path`/`artifact_path` are relative to `CAD_ARTIFACT_PATH`;
`artifact_path` is `"<run_id>/artifacts"` only when files were collected. A
collection skip is `artifact_error: "collect_skipped"`, not a status change. The
Docker client is injected via `:actions_docker` (`FakeDocker` in tests).
`Runs.list/get` now return `:disabled` when `CAD_ACTIONS_ENABLED=false`; run
pages redirect, the nav link hides, and artifact downloads 404.

Carry-over (post-Phase-7, optional):

1. **Phase 5 P5 docs live smoke** — with a real `CAD_LLM_API_KEY`.
2. **Optional `:CadProposals` surface** for the union token returned to Neovim.
3. **Manual styling check**: `docker compose up`, then `/`,
   `/p/cadence-demo`, `/p/cadence-demo/reviews`, a run page, one pending
   proposal, and `/proposals/<token>` at wide and narrow widths in light and
   dark. There are no browser tests; 4e and 6c verified server-rendered markup
   and CSS only.
4. **6c residues** (spec §16): run history pages at 50 rows and the detail at
   the first 100 artifacts (no paging); no per-project run concurrency cap; no
   artifact/image retention; action log streaming remains post-exit.
5. **7b/7c residues** (spec §16): pack consolidation / multi-pack index; no
   run timeout (a hung repack wedges the single-worker queue until restart);
   the repack threshold path was not exercised on the demo seed (its stores are
   below 1,000 objects — the manual two-run path was used, and the threshold is
   unit-tested).

**Spin-up:** `@phx-full` (or `@phx-quick` for the two review suggestions). The
planned build order in spec §13 is complete; no new dependency is expected.

## Blocked

- (none). Phase 7 is complete (7a–7d), every review's must-fix item is applied
  and verified, and both freshness-review suggestions are fixed. Pre-existing
  follow-ups (unreadable-object isolation, re-push of an existing row whose
  objects were later lost, the 8 MB retry ceiling, pack consolidation, the
  missing repack timeout) remain recorded below and in spec §16.

## Spec Deltas / Open Items

- **Post-7d quarantine retry scope (2026-11-07)** — `ProjectLive` now caches
  only authoritative quarantine answers and retries a failed scan on the next
  navigation or incident event. A Run click still reuses the rendered answer, so
  an owner needs one event/navigation before running against a snapshot whose
  earlier scan failed; staging remains the authority and the refusal is
  fail-closed, so wiring the click to re-derive is a refinement, not a safety
  gap.
- **7d verification notes (2026-11-07)** — the demo seed's stores are 29 and 36
  loose objects, far below the 1,000-object / 64 MiB default threshold, so the
  smoke exercised the **manual** `mix cadence.repack` path (two runs: pack, then
  verified sweep). The threshold and push-trigger paths stay covered by
  `storage_repacker_test.exs`, but a real over-threshold push was not driven.
  The repack ran in a second VM while the server was live: the server served
  every page correctly because a packed-only read misses loose, reloads the
  index once, and retries (7a), which is now exercised end to end. Two packs
  were observed only in the test suite (split batches); the smoke produced one
  pack per project. Pack consolidation/multi-pack-index remains open (§16).
- **7c handshake notes (2026-11-07)** — `objects_from/2` returns the **full
  reachable closure** for every node, so a push batch's unique SHA set is
  roughly the project's whole history, not the new delta. That is why the
  handshake **chunks** (`CAD_SYNC_EXISTS_LIMIT` per request) instead of skipping
  over-cap batches: a flat cap would silently disable the optimization on any
  real repository. A non-positive value disables it explicitly. Requests are
  sequential, so a very large batch adds round trips but still filters; any
  failed chunk sends the whole batch unfiltered. `present_shas/2` reads the pack
  cache without reload-on-miss, so a cross-VM repack can produce a stale-*absent*
  answer — safe (the daemon resends) and a genuinely missing object is a 422
  followed by one full-object retry. The retry is per spec on **any** 422 from a
  filtered push, so a batch whose full payload exceeds the endpoint's default
  8 MB parser limit can go 422 → retry → 413 and cannot self-heal; such a batch
  could not push unfiltered before 7c either. Two pre-existing follow-ups are
  **not** fixed here: a `{:objects, node_id, reason}` load failure still fails
  the whole batch instead of isolating that node, and re-pushing an existing
  node row skips `import_objects`/`ensure_complete`, so objects lost later from
  the store are not detected.
- **Repacker 7b notes (2026-11-07)** — deletion needs **two** runs by design:
  the writing run never unlinks (OTP cannot fsync a directory), and the next
  run re-reads each covered entry through the pack and re-hashes it before
  `File.rm`. Loose objects therefore count toward the threshold even after a
  pack covers them; that is what makes the next check the sweep, and it means
  pack + loose coexist for at most one trigger/backstop interval (budget 2×
  object storage). The advisory lock is **transaction-scoped** and the file
  work runs inside `Repo.transaction`, so a run holds one pooled connection and
  — if the DB backend is terminated mid-run (network drop,
  `idle_in_transaction_session_timeout`) — the lock is released while the run
  continues. That is accepted: concurrent runs use atomic renames,
  content-addressed writes, and verify-before-delete, so the worst case is
  wasted work/duplicate packs. Crash debris and half-completed renames are only
  removed after a 5 minute grace (module constant, not env) so a writer whose
  lock was lost is never mistaken for garbage. The read path still validates
  zlib + declared size, not the SHA (7a contract); only the repacker's
  `verify_packed/2` and `read_loose_raw/2` re-hash. There is no run timeout: a
  hung run wedges the single-worker queue and holds the lock (the next
  Repacker generation or the CLI reports `:busy`, never corrupts). Queue and
  cooldown state are in-memory, so a Repacker restart loses them (the backstop
  re-derives work; an orphaned in-flight task finishes alone). Each run adds a
  pack; there is no consolidation/multi-pack index and corrupt `pack-*` pairs
  are deliberately kept (they may be the only copy of already-swept objects).
  Real lock contention cannot be exercised in the sandbox (one connection per
  test); tests cover sequential release plus the injected `:busy` seam.
- **Pack layer 7a notes (2026-11-07)** — pack entry ends come from the idx
  offsets (the compressed slice ends at the next offset/trailer), not from
  zlib: `safeInflate/2` can return `:finished` on a partial stream. The cache
  is explicit-invalidation plus reload-on-read-miss; an out-of-process writer
  (manual repack in another VM, another node) cannot clear this VM's ETS table,
  so reads reload once on a packed miss. The 7c handshake tolerates a stale
  "absent" answer (the daemon resends; a server 422 triggers one full resend).
  OTP cannot fsync a directory, so 7b deletes loose copies only in a later
  verified sweep; the writing run never deletes. Pack reads cap declared sizes
  at 512 MiB and stream inflate; delta chains cap at 50; duplicate SHAs are
  dropped/rejected; `has_object?` rejects non-hex 40-byte input. See spec
  §13/§16 and `.claude/solutions/data-integrity/pack-v2-byte-format-20261107.md`.
- **`walk_blobs/3` truncation fix changes scan outcomes (2026-11-06)** — the
  shared walk previously dropped every sibling after a directory; it now scans
  the full tree. Consequences: a snapshot can newly quarantine (correct), new
  pushes may open incidents for previously missed content (existing rows are
  not rescanned), `Proposals.verify_first_parent/2` maps an over-cap parent to
  `:missing_parent` (so a previously truncated over-cap parent now blocks
  approval), and `ProposalView`/`Melds` walks may newly hit `:too_large`.
  Regression tests pin the walk; the lesson is in
  `.claude/solutions/data-integrity/walk-blobs-truncation-20261106.md`.
- **Actions 6a notes (2026-11-06)** — the manifest is read from the node's Git
  tree on every navigation (one bounded blob read; no extra query); callers own
  quarantine (the LiveView hides the panel, 6b must re-check at the run
  boundary); the manifest file itself remains publicly browsable repository
  content; `Project.actions_manifest` is still unused; `expose` is parsed and
  reserved — 6c resolved it as unhonored while the panel stays members-only
  (§16). 6b resolved run durability with a durable row; artifact and image
  retention remain open (§16).
- **Actions 6b notes (2026-11-06)** — `execute/1` is synchronous and `start/4`
  wraps it in `Actions.TaskSupervisor`; `recover_stale/2` CASes per row, and
  `list/get` call it with `remove_containers: false` so reads never touch
  Docker. `container_id` is recorded after create and cleared only after a
  confirmed removal; terminal rows with a retained id are swept by
  `recover_all/0` and the manager-triggered `start/4`. `Actions.Docker` is the
  injection point (`:actions_docker`); `DockerEngine` defaults to API `v1.45`
  (`CAD_DOCKER_API_VERSION`) with no negotiation, because that is the
  `volume-subpath` floor for Docker 26–29. Logs are TTY output (stderr merged),
  tail-capped and stored at `<run_id>/output.log`; artifacts at
  `<run_id>/artifacts/`. `/out` is world-writable (0777) so non-root images
  work. Deployment prerequisites: a size-limited `CAD_ACTIONS_VOLUME_PATH`
  filesystem, a socket proxy treated as root-equivalent (and never on an action
  network), and awareness that `Dockerfile` `FROM` pulls are daemon-side. Still
  open: artifact/image retention, per-project run concurrency,
  `Project.docker_image` has no writer, userns (§16).
- **Actions 6c notes (2026-11-07)** — run pages authorize in `handle_params/3`
  (the same accepted exception as `ReviewLive`: the static render performs two
  indexed lookups, while expensive run/log/artifact data stays in
  `assign_async`). A Run click re-reads membership, reuses the rendered
  quarantine answer in normal view, and re-derives it only in raw view (where
  the answer was forced to `:ok`), so the normal path keeps the single staging
  scan; staging remains the authority. `Runs.start/4` moved `recover_stale/1`
  (and orphan container removal) inside the spawned task, so the click never
  blocks on the Docker proxy. `Runs.list/get` require `CAD_ACTIONS_ENABLED`
  (`:disabled`); the pages redirect, the nav link hides, and downloads 404.
  Logs are post-exit; the page follows `{:action_run_updated, …}` and renders
  `Presentation.terminal_text/1` output (ANSI/OSC, C0/C1, bidi stripped; invalid
  UTF-8 replaced) in an escaped `<pre>`. Artifact downloads accept only an exact
  path from `Artifacts.list/1` (controller wildcard params arrive as a list and
  are joined first), serve `application/octet-stream` + `attachment` +
  `private, no-store`, and map a vanished file to 404. The run list shows 50
  rows and the detail renders the first 100 artifacts (no paging yet, §16).
- **Phase 5b implementation notes (2026-11-06)** — every commit gets a
  `SyncPending` row written in the same transaction as the node (and spawn);
  `pushable/3` keeps a doc-held parent in the parent set and gates only
  *selection*, so children cannot overtake it and the server still receives one
  node at `C2`. Sync gating keys on the explicit
  `session_metadata["docs"]["state"] == "pending"` marker; plain
  `docs_state: :pending` legacy nodes (4c meld approvals) stay pushable.
  `retry_pending/0` is project-scoped, moves a deferred node back to `pending`
  before retrying, and the reconnect hook fires only on a per-project
  offline→online transition, so a failing job is not retried every pass.
  Terminal errors are `:not_configured`, `:missing_code_commit`, `:no_location`,
  `:too_many_docs`, and `:context_too_large`; everything else retries with
  linear backoff. Docs reads are capped by `CAD_DOCS_MAX_FILES` (200) and twice
  the prompt budget; unlisted/over-budget docs are read-only to the agent.
- **Watcher commits skip unchanged trees (5b)** — `CommitQueue.commit/3` accepts
  `skip_unchanged: true` and the watcher passes it. This is the second guard
  against the doc feedback loop: suspension alone cannot cover an inotify event
  that arrives just after `resume`, or a polling backend's post-write tick.
  Explicit/API commits still create an empty commit when asked.
- **Doc commit SHA gating/fallback (5b → P4, closed by P4-T2)** — selection
  gating is implemented and tested, and `mark_pushed/1` stamps a top-level
  `session_metadata["docs_pushed_sha"]` (covering `:skipped` nodes) so
  `rehydrate/0`, `retry_pending/0`, and the job runner never rewrite an
  already-pushed SHA. A forced no-op run keeps the previous `C2`. P4-T1 closed
  the reconnect hole by running the retry *before* the pass pushes. P4-T2
  closed the remaining hole: a node pushed before its docs resolved (mid-job
  push, manual sync after a code-only push, or a retry of a pushed deferred
  node) keeps its SHA and attaches the docs as a child node; `already_synced`
  no longer exists. **Residual:** a push that *completes* after the local `C2`
  write is invisible to the compare-and-swap (the stamp has not landed yet), so
  the server can hold `C1` while the local row says `C2`. The stamp then routes
  the next retry to a child, so it is recoverable, but a push-in-flight marker
  would be needed to close it fully.
- **P4-T2 write/retry notes (2026-11-06)** — the in-place docs write is a
  compare-and-swap on `json_extract(session_metadata, '$.docs_pushed_sha')`
  (SQLite-only, matching the daemon Repo boundary) with one re-read on a miss;
  `Session.docs_after/3` is a single conditional `update_all` so a user switch
  wins; a pushed node with `CAD_DOCS_ENABLED=false` keeps its deferred state
  instead of terminalizing to `:skipped`; and the watcher stays suspended across
  the node write, closing a duplicate-node window. A pushed parent keeps its
  server-side `docs_state: :pending` forever (its snapshot is immutable) — the
  docs child carries `:current`; P4-T3 renders the node's own state and links
  the child node.
- **Server-created meld nodes never reach docs `:current` (P4-T3 review W1,
  2026-11-06)** — approval inserts a meld node with `docs_state: :pending`
  (§6.5), but doc generation requires local provenance (a `SyncPending` row or
  a pushed-SHA stamp) and a pulled node is `:legacy` on the daemon, so no job
  will ever move that row to `:current`. The badge therefore shows "docs
  pending" indefinitely for such nodes. Recorded in spec §9.4 and §16 as an
  open decision (`:skipped` at approval vs. an explicit pulled-node generation
  flow); not fixed in the badge slice.
- **Reconnect doc retries while the server is still down (P4-T1)** — the
  trigger is `last_status != :ok`, so a project that keeps failing every pass
  re-asks `DocQueue.retry_pending/1` on each pass (30 s at defaults). That is
  intentional early on (the docs can be generated offline and wait at `C2`), and
  the `:docs` Hammer limiter bounds the model cost, but a permanently broken doc
  client during a long outage will churn the queue. Add a per-node retry marker
  if that shows up in practice; once a pass succeeds the guard stops the
  retries and the node syncs code-only.
- **Phase 5c implementation notes (2026-11-06)** — `POST /docs/sync` resolves
  `node_id` to `Session.anchor_node/1` when omitted and returns `202` with the
  resolved `node_id`; the skip reasons are `already_current`, `legacy`,
  `disabled`, `no_schema`, and `invalid_schema` (P4-T2 removed
  `already_synced`: a pushed node queues a child job). Manual sync respects
  `CAD_DOCS_ENABLED` (spec §9.2) instead of overriding it. `GET /docs/diff` also
  defaults `node_id` to the anchor, returns `400` without `project_id`, `404`
  for an unknown node/commit, and `409` for no docs commit or no schema.
  `DocDiff.build/2` accepts `nil`. The Neovim commands accept an optional node
  id; `:CadDocSync` uses `post_async`, and `:CadDocDiff` renders through
  `cadence.doc.format/1` (which wraps `diff.lua`).
- **Phase 5a implementation notes (2026-11-06)** — `docs_state` semantics are
  now explicit in spec §9.4 (`:current` generated/committed, `:pending`
  queued/deferred/retrying, `:skipped` no schema/trigger). `build_prompt/4`
  returns `writable_paths`/`read_only_paths`; P2 passes `read_only_paths` to
  `parse/3`.
- **`Project.docs_schema` server propagation is deferred** — `.caddocs.yaml`
  remains the source of truth; P2 caches the parsed map locally on the project
  row. Syncing it to the server is future work.
- **Web docs review remains deferred** (spec §16) — Phase 5 ships
  `:CadDocSync`/`:CadDocDiff` plus a read-only `docs_state` badge; rejecting
  generated docs needs a review object that does not exist yet.
- **Doc `max_words` is advisory** — the schema parses and records it, but the
  required-heading check does not enforce a word count. Revisit if docs grow
  unbounded.

- **`proposal_url` assumes `CAD_SERVER_URL` is public (4d-3)** — the daemon
  builds the link from its API base. If a deployment points the daemon at an
  internal/docker URL while `CAD_PUBLIC_URL` differs, the notification link is
  unreachable. The server already knows `public_url`; returning it in the union
  response would remove the assumption.
- **The union picker is not live-smoke tested (4d-3)** — `ui.lua`,
  `client.lua`, and the plugin pass `luac -p` and the daemon API is covered by
  tests, but no Neovim instance was driven against a daemon/server for this
  session. Drive `:CadUnion` once against the demo stack and record the result.
- **`CAD_SYNC_ENABLED` gates only background sync (4d-3)** — a union still
  attempts when it is `false` as long as `CAD_SERVER_URL`/`CAD_AUTH_TOKEN` are
  set (and reports 503 when they are not). Spec §6.5 now says offline union
  reports 503 after submit rather than greying the command out.
- **The union request is synchronous end to end (4d-3)** — the editor is async,
  but the daemon holds one HTTP request open while the server may retry the
  model (~120.5 s at defaults). A job/queue remains an open delta.
- **Pin convergence is best-effort after commit (4d-1)** — the pin is committed
  first, then `Sync.touch_node/1` bumps `nodes.seq` outside the transaction
  specifically so a concurrent pull cannot advance past an uncommitted token.
  If the bump itself fails (DB error), the pin stands but daemons receive it
  only on the next change/poll; the failure is logged by shape. The same
  applies to `SyncNotifier.project_changed/1`: the write is already committed,
  so a notification failure is swallowed after a warning.
- **Approval integrity now walks twice (4d-1)** — the decision walks the result
  under the scan caps **and** the first parent's commit/tree/blobs, then the
  rendered diff walks the parent again. All are capped and approval is not a
  hot path; consolidate into one walk if that changes.
- **`{:nodes_pushed, ...}` is "node changed" (4d-1)** — emitted for a created
  meld node or a pin that actually flipped; an already-pinned target or an
  idempotent re-decision emits only `proposal_decided`. No consumer yet.
- **Proposal result scanning has two scopes (4a-2 → 4c-3)** — the rendered diff
  filters sensitive paths and content-scans only visible files, while incident
  resolution re-scans **all** result blobs (a hidden-path filename alone keeps
  an incident open, because the creation check quarantines it too). Recorded in
  spec §7.6 ("Proposal results (4a-2 / 4c-3)"). Content rendering on the review
  surface is still deferred, so the gap is closed for now.
- **Integrity incidents are effectively permanent (4c-3)** — resolution now
  re-asserts `meld_commit_sha`'s tree equals `result_tree_sha`, so an
  `approval_integrity` incident never clears while the mismatch holds; the only
  exit is reject + re-propose. This is deliberate (D8), but it means a
  transient store problem that later becomes consistent **and** leaves the
  proposal row unchanged still cannot be resolved. Recorded in spec §6.7.
- **Acknowledgment is a nil clause (4c-3)** — plan D9 says node/project
  incidents resolve with *no* verify callback; the implementation always passes
  `ProposalView.verify_resolution/1`, whose `proposal_id: nil` clause is the
  acknowledgment path. Behaviour is identical and the context still owns the
  "no scan" decision; kept because passing different opt lists would duplicate
  the branch in the LiveView. Documented in spec §6.7 as acknowledgment.
- **Incident list is capped at 50 (4c-3)** — `Incidents.list_open/2` returns at
  most `max_open_incidents/0` rows. Critical incidents sort first, so the cap
  only hides lower severities; the panel says "Showing the 50 newest open
  incidents" when truncated. No paging/deep-link to older incidents yet.
- **Verification runs outside the resolution lock (4c-3)** — `Incidents.resolve/4`
  loads and verifies the incident before the `FOR UPDATE` transaction, so a
  filesystem scan never holds the row or a pool connection. Two concurrent
  resolvers may therefore both scan before one writes; the write is idempotent
  and incident targets are immutable, so the duplicate scan is accepted.
- **`verify_resolution/1` goes beyond plan P2-T10** — it returns
  `integrity_failed` (in addition to `still_risky | unverifiable`) and the UI
  flashes "reject and re-propose". Review finding M1; recorded in spec §6.7.
  Since 4d-1 it re-runs the whole `result_integrity/3` check, so a
  `missing_parent` incident is also unclickable.
- **Demo-only password auth** — resolved 2026-11-05: spec §7.4 records the
  compile-gated `CAD_DEMO_AUTH` strategy, §11 the `bcrypt_elixir` dependency,
  §12.4/§12.5/§12.6 the demo stack and the build-time exception.
- **Demo dev reload is refresh-based** — plan T14 asked for `live_reload`; it
  needs `phoenix_live_reload`, which is not in spec §11, so only
  `code_reloader: true` shipped. CSS is bind-mounted and templates recompile on
  the next request. Add the dep (and a spec §11 row) if push-based reload is
  wanted.
- **Demo seed tags proposals in `result_metadata`** — the seed writes a
  `%{"demo" => label}` map directly on the five demo proposals so the summary
  can name tokens (two are pending melds). `result_metadata` stays out of the
  changeset cast list; the seed is server-side and `mix`-only.
- **The demo stack is not a release artifact** — `docker/Dockerfile.demo` builds
  `MIX_ENV=dev` and keeps sources for `code_reloader`; spec §12.8 (release
  image) remains open work.
- **Live DAG refresh is not subscribed (4e-1)** — `ProjectLive` ignores
  `{:nodes_pushed, …}`: `DAGLayout.layout/2` recomputes intro timing, so a live
  refresh would replay the animation and can disturb the selected pane. Revisit
  only with a stable re-layout that preserves the selection and skips the intro.
- **Membership changes have no broadcast (4e-1)** — there is no event source
  for role edits. Review pages refresh `can_decide?`/`can_manage?` on the next
  project event, and every mutation still re-reads the membership and fails
  closed.
- **`Presentation` classes fall back to neutral (4e-2)** — an unrecognized
  proposal status, severity, or file status renders the neutral badge rather
  than failing. A new status/severity needs a variant in both the helper and
  the CSS; only the neutral styling signals a miss.
- **The 4e palette was not checked in a browser (4e-2)** — severity/status
  tokens alias existing palette values, so contrast is inherited, but the
  light/dark render was not exercised visually. The optional demo check in
  **Next** covers it.
- **Result markup is still duplicated (4c-2 → 4e)** — the review page repeats
  the public proposal result block (`proposal_html/show.html.heex`) with its own
  isolation sentinel. The format/badge helpers now live in
  `Cadence.ServerWeb.Presentation` (4e), so the remaining work is the result
  component itself; extract it when the public page next changes.
- **`{:nodes_pushed, ...}` semantics (4c-1)** — emitted only for meld
  approvals (plan D11), including when an already existing node was merely
  re-pinned; promotions broadcast `{:proposal_decided, ...}` alone, so 4d
  consumers will not see the pin change from that event. Idempotent
  re-decisions repeat `{:proposal_decided, ...}` with the stored status.
  Decide the final event contract in 4d.
- **Integrity incident dedupe keeps the first reason (4c-1)** — the unique
  open (proposal, kind) index means a second integrity failure with a different
  reason reuses the open `scan_incomplete` incident, so `details.reason` can be
  stale. The safety net still holds because approval re-verifies.
- **`Proposals.create/2` validates SHA shape only (4c-1)** — a proposal can be
  created whose result objects were never materialized (or were pruned). It is
  then permanently unapprovable (`:integrity_failed`, then `:blocked`). Only
  `Melds.propose/3` calls `create/2` today; when 4d wires union/pull, verify
  objects at creation so a broken result never reaches the review queue.
- Public proposal reads are uncached: two capped blob walks plus a full regex
  scan per GET, with no rate limit. If latency matters, 4c can materialize a
  stored diff keyed by result commit.
- The public proposal page lives in the `:browser` pipeline, so its body
  includes a per-request CSRF token (session-free and cacheable output would
  need a dedicated pipeline).
- **Push scan cost (4b-2)** — every new snapshot is scanned synchronously in the
  push request with one capped `walk_blobs/3` per inserted node, so a large
  snapshot pays that cost once per node. Only newly inserted
  nodes are scanned; re-pushes of existing nodes are not rescanned, and a later
  store corruption is caught by the read path, not by a new incident.
- **Node incident resolution is acknowledgment (4b-2)** — resolving does not
  bypass the read-time scan, so a genuine secret stays quarantined until a new
  node carries the rotated content. 4c's panel must not present resolution as
  "restore". Recorded in spec §6.7.
- **Push-scan alerting is best-effort (4b-2)** — a failed incident insert never
  fails the push; the read-path scan still quarantines the content, but the
  alert is lost until the next event.
- Proposal JSON representation and parent selection are not planned; line-level
  diffs and file content remain deferred to the UI pass.
- Proposal decisions are resolved (spec §6.6/§16): single approver, promotion
  via `pinned`, public read-only links with filtering/quarantine, and meld
  results materialized at proposal creation.
- Incidents (§6.7) ship as open/resolved alerts only. Assignee, comments, and
  external issue-tracker integrations are deferred.
- Public proposal links must respect project visibility if/when per-project
  publishing lands.
- Syntax highlighting remains deferred; file content is escaped plain code.
- Public `broken`/`sandbox` nodes and snapshots are visible; revisit if that
  proves undesirable.
- Secret filtering is best-effort, not a guarantee. Per-project overrides and
  reveal auditing are deferred; owners must rotate leaked secrets.
- Unknown project pages render HTTP 200 with a not-found view (LiveView mount
  cannot set 404 after render); proposal pages do return a real 404.
- `Project.visibility`/publishing is deferred; all projects are public by
  default.
- **4b shared caps** — `Shared.Meld.apply_ops/3` and `LLM.Meld.build_prompt/3`/
  `parse/3` take caps as options (the shared app must not read server config);
  the server passes `CAD_MELD_*` values. Documented in spec §6.5/§11.
- **4b has no trigger surface or job durability.** `Sync.Union` /
  `UnionResponse` remain unrouted, and the response shape (proposal token vs
  node) is unresolved until 4d.
- **Meld queue dedupe is sequential only (4d-2)** — `Melds.propose/3` returns
  an existing **pending** meld for the same ordered parents, so retries and
  double submits do not flood the queue. Two requests racing in the same
  instant can still both miss the lookup and create two rows (no unique index);
  rejected proposals do not block a new attempt.
- Meld validation syntax-checks only `.ex`/`.exs`; other languages are
  reviewer-checked once review renders file content (not in 4c — it renders
  paths only).
- `result_metadata` is server-owned and never cast; it is still not surfaced in
  the review UI (optional 4d/UI-pass work).

## Last Updated
2026-11-05 — 4c-3 (incident panel + resolution) shipped from
`.claude/plans/review-ui-4c/plan.md` P2-T9..P3-T2: incident panel on the review
hub, `resolve_incident` with a fresh role check, `ProposalView.verify_resolution/1`
(re-scan + tree invariant), resolution verification moved before the row lock,
`list_open/2` capped at 50, and spec §6.6/§6.7/§7.1/§7.2/§7.6/§13 updates.
Independent review verdict PASS WITH WARNINGS; all four Mediums fixed (integrity
incidents can no longer be dismissed while the tree mismatches, scan off the
lock, `:unverifiable`/hidden-path/integrity/promotion/cross-project tests added)
plus the Lows (closed authorization assertion, refreshed `can_decide?`, summary
computed once with an ellipsis, log shape only). Verification: format/compile
clean in dev and prod, 565 tests green (161 + 115 + 289). Next slice is 4d; the
UI styling pass follows it, with notes in `docs/ui-notes.md`.

2026-11-05 — **4d-1 (convergence + pre-4d cleanup)** shipped the first session
of `.claude/plans/4d-convergence/plan.md` (P0 + P1). `SyncNotifier` fans
`sync_available` to every member on pushes/decisions/pin changes; decisions
emit `nodes_pushed` only when a node is created or its pin flips (promotions
included); pinning bumps `nodes.seq` **after** the pin commits and the daemon
applies only `pinned` on a re-pulled row; `result_integrity/3` is capped
(`:too_large`) and requires the first parent to be walkable
(`:missing_parent`), and resolution re-runs it. Review verdict PASS WITH
WARNINGS; all three Mediums fixed (post-commit cursor bump, parent-tree check,
approval-cursor tests) plus the Lows (node-changed semantics, full integrity on
resolve, locked pin compare, non-raising `touch_node`, best-effort fan-out,
per-topic notification tests, §16 resolved). Verification: format + dev/prod
compile clean, 578 tests green (161 + 116 + 301). Next: 4d-2 (union route).

2026-11-05 — **4d-2 (union route)** shipped: `POST /sync/union` delegates to
`Melds.propose/3` synchronously and returns the proposal reference; the
controller maps 403/404/422/429(+Retry-After)/502/500 without leaking
internals. `Melds.propose/3` dedupes a pending meld for the same ordered
parents, caps parents at 8, and the meld limiter is keyed per project.
`UnionResponse` is no longer `meld_node_id`. Review verdict PASS WITH WARNINGS;
H1 (uncapped parents) and all three Mediums fixed (parent cap, documented
retry×timeout latency, 429 mapping, queue dedupe), plus the Lows (scan 5xx,
403 wording, struct response, moduledoc, test gaps). Verification: format +
dev/prod compile clean, 587 tests green (161 + 116 + 310). Next: 4d-3
(daemon + Neovim trigger).

2026-11-05 — **4d-3 (daemon + Neovim union trigger)** completes Phase 4.
`:CadUnion` submits asynchronously through the daemon (`POST /union`) to
`POST /sync/union`; the picker keeps selection order, the daemon provisions and
pushes pending parents first, and the result notifies the proposal token/URL.
`CAD_SYNC_UNION_TIMEOUT_MS` (180 s) covers the server's `(retries + 1) ×
timeout` bound; transport failures map to 503/504, server statuses pass
through, and rate limits say "retry shortly". Review verdict PASS WITH
WARNINGS; H1 (blocking `<C-s>`) and six Mediums fixed (async submit, status
mapping, ordered parents, push-before-union, timeout formula, passthrough
tests), plus the Lows. Verification: format + dev/prod compile clean, `luac -p`
clean, 596 tests green (161 + 125 + 310). Remaining: UI styling/freshness pass
and Phase 5 docs automation.

Session closed 2026-11-06 — Phase 4 is complete at `f4161a8`; working tree
clean. Next session starts the UI styling/freshness pass (see **Next** above;
spin-up command included there). Server tests need Postgres on `localhost:55432`:

```bash
docker run --rm -d --name cadence-test-pg \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=cadence_test \
  -p 55432:5432 postgres:16-alpine
```

2026-11-06 — **UI freshness, Session A (4e-1)** shipped from
`.claude/plans/ui-styling-freshness/plan.md` P0–P2: `Incidents` broadcasts
`{:incidents_changed, …}` on a new insert or an open→resolved transition and
`Proposals.create/2` broadcasts `{:proposal_created, …}`, both after commit and
best-effort with shape-only logging; `ReviewLive.Index`/`Show` subscribe to
`project:<id>` after connect (guarded by `subscribed_project_id`) and refresh on
the events they can act on — Show reloads only its own proposal and ignores node
incidents — refreshing `can_decide?`/`can_manage?` per event; `ProjectLive` drops
the cached quarantine assign and reacts to incident events for the selected node
only, never refreshing the DAG. Spec §6.6/§6.7/§7.2 updated. Verification:
format + dev/prod compile clean, 619 tests green (161 + 125 + 333; +23 new).
Session B (styling, P3–P4) is next — resume with `--from P3-T11`.

2026-11-06 — **UI freshness review → triage fixes.** `/phx-review` verdict PASS
WITH WARNINGS; all four findings fixed per
`.claude/plans/ui-styling-freshness/reviews/ui-styling-freshness-triage.md`:
Show now treats a critical incident on the node it would promote/attach as
blocking (`Proposals.decision_node/1` mirrors `ensure_node_approvable/2`, the
payload carries `node_blocked?`, Approve is hidden with a blocked reason, and
the event reloads it), an unrelated node incident is still ignored;
`Incidents.resolve/4` detects the transition inside the `FOR UPDATE`
transaction so concurrent resolves cannot double-broadcast; `ProjectLive` keeps
a quarantine cache keyed on `{node_id, blocking_node?}` — tree/blob patches
reuse the snapshot scan, incident flips re-derive, no stale assign; Show
normalizes the URL proposal id with `UUID.cast/1` so mixed-case links keep live
updates. Spec §7.2 wording corrected. Verification: format + dev/prod compile
clean, 622 tests green (161 + 125 + 336; +3 new, 1 extended).

2026-11-06 — **UI styling, Session B (4e-2)** completed
`.claude/plans/ui-styling-freshness/plan.md` P3–P4 (P3-T11..T16,
P4-T17..T20). `Cadence.ServerWeb.Presentation` is now the only source for the
format/badge/file-status helpers (15 tests); `Components.Incident` moved the
open-incident panel above the queue with an `aria-live` count, severity
treatment, a full-reason `<dl>`, and distinct Resolve/Acknowledge controls with
inline copy; CSS gained semantic severity/status tokens, badges, callouts,
button modifiers, review-queue layout, and file-status colors; the public
proposal, project, and portfolio surfaces share the vocabulary. Spec §13
records 4e and §16 resolves review/promotion placement; `docs/ui-notes.md`
moved its observations to Done; `docs/README.md` status table corrected.
Verification: format clean, dev/prod compile clean, 639 tests green
(161 + 125 + 353; +17 new). Review pending. Next: Phase 5 (spec §9).

2026-11-06 — **4e styling review → triage fixes**
(`.claude/plans/ui-styling-fixes/plan.md`, from
`reviews/ui-styling-freshness-styling-triage.md`). Light-mode contrast restored
with `--*-text` tokens (text 6.1–7.5:1 while the hue tokens keep borders,
tints, row accents, and the severity marker); the DAG's pinned/flagless
normalization is pinned by a component render test (`pinned`, was
`no flags · pinned`); incident links use `~p`; the `aria-live` summary includes
the critical-count line, asserted by containment (`has_element?`) rather than
document order; README status corrected. Verification: format clean,
dev/prod compile clean, 640 tests green (161 + 125 + 354; +1). Deferred:
5-pattern cap, double `details_pairs/1`, manual light/dark demo check. Next:
Phase 5 (spec §9).

2026-11-06 — **Phase 5a (doc automation shared primitives)** shipped and
committed (`feat: Phase 5a — doc schema, trigger, and prompt primitives`).
`Cadence.Shared.Docs.Schema` parses/validates `.caddocs.yaml`; `Glob` matches
`generated_from` patterns without touching disk; `Docs.Trigger` gates on
generated paths, schema changes, and an API-surface heuristic;
`LLM.Docs` builds a bounded prompt and strictly parses MODIFY/CREATE ops with
read-only-path protection; `UTF8` centralizes the invalid-UTF-8-or-NUL rule;
`GitStore.merge_files/3` overlays only affected subtrees. `yaml_elixir` is a
direct `cadence_shared` dependency; spec §9.1/§9.3/§9.4/§9.5, §11, §12.6, and
§16 were updated. `/phx-review` verdict PASS WITH WARNINGS; all 5 findings
fixed via triage (read-only doc writes, binary diff omission, NUL/control path
rejection, path-directed merge, `apply_ops` CREATE/MODIFY validation).
Verification: `mix format --check-formatted` and
`mix compile --warnings-as-errors` clean; 248 shared + 125 daemon tests green
(server suite not rerun — no Postgres). Next: 5b (P2-T1) daemon doc worker.

2026-11-06 — **Phase 5b (daemon doc worker + commit integration)** shipped
`.claude/plans/phase-5-docs/plan.md` P2-T1..T11. `SchemaSource` reads
`.caddocs.yaml` and caches `Project.docs_schema`; `CommitQueue` evaluates the
trigger, sets `docs_state`, records `code_commit_sha` only for queued jobs, and
leaves the sync enqueue to `DocQueue`; `DocQueue` runs `DocAgentWorker`
(Task.Supervisor + Hammer `:docs`, injectable `:docs_llm`, bounded timeout),
writes `C2` with `merge_files/3`, updates the node, and defers with a
shape-only error after `CAD_DOCS_RETRY_ATTEMPTS`. Working-tree writes are
schema-scoped, watcher-suspended, and skipped when the user diverged
(`workdir_skipped`); watcher commits now pass `skip_unchanged: true` so a late
event cannot create an empty node. `SyncLedger` holds doc-pending nodes out of
enqueue/backfill/pushable; `DocDiff.build/2` returns the schema-filtered
`C1→C2` diff; `retry_pending/0` re-gates deferred nodes on a reconnect
transition and `rehydrate/0` resumes them at boot. Verification:
`mix format --check-formatted` and `mix compile --warnings-as-errors` clean;
756 tests green (251 shared + 151 daemon + 354 server). Review pending. Known
risk recorded in Spec Deltas: deferred-retry-after-push awaits the P4-T2
child-node fallback. Next: 5c (P3) — daemon `/docs/sync` + `/docs/diff` and
`:CadDocSync`/`:CadDocDiff`.

2026-11-06 — **Phase 5b review → triage fixes.** `/phx-review` verdict
REQUIRES CHANGES: B1 (a child could be pushed before its doc-held parent →
server `unknown_parent` 422 with a 24 h backoff), W1 (boot rehydrate rewrote an
already-pushed deferred SHA → 409), W2 (a raising job stranded the node
forever), W3 (spec §9.5 contradicted D6), W4 (empty generation claimed a `C2`),
W5 (test timing/isolation), plus S1–S9. All findings fixed per
`.claude/plans/phase-5-docs/reviews/phase-5-docs-5b-triage.md`: every commit
gets a sync row and `pushable/3` gates selection only, `mark_pushed/1` stamps
`pushed_sha`, a rescue + non-raising writes defer a crashed job,
empty generations record `"empty": true` (no `C2`), `CAD_DOCS_MAX_FILES` was
added to §12.6, `retry_pending/1` is project-scoped, `:force` sync falls back to
`node.git_commit_sha`, worktree writes reject symlinks, `docs_enabled?`
releases queued nodes as `:skipped`, and the tests use a barrier/queue
drain/`:fs_poll` instead of races. Spec §9.2/§9.4/§9.5/§12.6 updated.
Verification: format + dev/prod compile clean; 764 tests green
(251 shared + 159 daemon + 354 server). Next: 5c (P3).

2026-11-06 — **Phase 5b second review.** The post-triage re-review found three
remaining warnings and all were fixed: (1) the pushed-SHA stamp moved to a
top-level `session_metadata["docs_pushed_sha"]` so `:skipped` nodes are
protected too and the ledger never rewrites the `docs` state machine;
(2) `SyncPending` is now inserted inside the node transaction (commit and
spawn), so a dropped notification cast cannot leave a parent rowless and let a
child be pushed first; (3) a forced no-op run keeps the previous
`docs_commit_sha` instead of rewinding a node from `C2` to `C1`. Tests added:
skipped-node force guard (no model call), atomic sync row, repeated-force `C2`
preservation. Verification: format + dev/prod compile clean; 766 tests green
(251 shared + 161 daemon + 354 server). Next: 5c (P3).

2026-11-06 — **Phase 5c (daemon doc API + Neovim commands)** shipped
`.claude/plans/phase-5-docs/plan.md` P3-T1..T5. `DocQueue.sync/2` performs the
manual-sync preflight synchronously (project/node/anchor, pushed guard,
`CAD_DOCS_ENABLED`, schema, LLM configured) and then queues with `force: true`;
`POST /docs/sync` returns `202 %{status: "queued", node_id}`, `200
%{status: "skipped", reason}`, `503`, `404`, or `422`. `GET /docs/diff` wraps
`DocDiff.build/2` (`200`/`400`/`404`/`409`), and both endpoints default
`node_id` to the session anchor (`DocDiff.build/2` now accepts `nil`). Neovim
gained a pure `cadence.doc` module (response mapping + a `C1 → C2` header over
`diff.lua`) so `:CadDocSync [node_id]` posts asynchronously and
`:CadDocDiff [node_id]` opens a scratch split or warns when there is no docs
commit. Manual sync now respects `CAD_DOCS_ENABLED` (resolving the 5b open
question) and a pushed node reports `already_synced` until P4-T2. Spec
§9.2/§9.4/§9.5/§12.6/§13 updated. Verification: `mix format
--check-formatted`, `mix compile --warnings-as-errors`, and `mix test` clean;
775 tests green (251 shared + 170 daemon + 354 server; 9 new router tests),
all Lua files pass `luac -p`, and `cadence.nvim/spec/doc_spec.lua` passes.
Next: P4 (deferred docs + polish).

2026-11-06 — **5c review + triage.** `/phx-review` verdict **REQUIRES
CHANGES**: B1 (the new manual endpoint can force-regenerate a pre-5b node whose
SHA was already pushed; `check_pushed` only trusts the 5b stamp, and the force
path falls back to `node.git_commit_sha`), W1 (a manual skip/503 does not
release a docs-held node, so it can stay out of sync), S1 (the plan's
“already current” skip is not implemented; current nodes force-regenerate),
S2 (the doc-diff split inherits wrapping). Triage selected all four; the user
chose `200 skipped, reason: "already_current"` for current nodes. Fix Queue in
`.claude/plans/phase-5-docs/reviews/phase-5-docs-5c-triage.md`. Fixes pending;
the gate and P4 wait for them.

2026-11-06 — **5c review fixes.** All four triaged findings shipped.
`DocQueue.check_forceable/1` requires a `SyncPending` row (`200 skipped,
reason: "legacy"` otherwise), so a pre-5b pushed node **or a pulled node**
cannot be force-regenerated and have its immutable SHA rewritten;
`already_current` is checked first. `resumable_nodes/1` requires the same row,
so boot/reconnect retries ignore pulled nodes. `maybe_release/2` releases a
docs-held node on a manual skip/error with the job's terminal transition
(`mark_skipped` for disabled/no_schema/legacy, `mark_deferred` for
invalid_schema/not_configured/no_location), so it cannot stay out of sync.
`check_current/1` returns `already_current` for generated docs; spawn nodes
(`:current` with empty metadata) remain forceable. The `:CadDocDiff` split now
sets `wrap=false`. Tests: legacy refusal + SHA unchanged, legacy-unpushed
allowance, pulled `retry_pending` guard, disabled/503/no-location held-node
release, already-current skip. Verification: format + dev/prod compile clean;
782 tests green (251 shared + 177 daemon + 354 server; +7); `luac -p` and all
Lua specs pass. Spec §9.2/§9.5 updated. Next: P4-T1.

2026-11-06 — **5c second-pass review fixes.** The re-review found two
ordering/race issues, both fixed. `DocQueue.sync/2` now marks the target
docs-pending (`docs_state: :pending`, `metadata["docs"]["state"] = "pending"`,
`code_commit_sha`) and re-enqueues sync before the cast, so `SyncLedger` holds
the node while the model runs; `maybe_requeue/1` reuses the same
`mark_pending/1`. `mark_current/5` re-reads the node and returns `:pushed` when
a `docs_pushed_sha` appeared while the job ran; `:pushed` is terminal, the node
stays at the pushed `C1`, and `mark_deferred` records the docs as deferred
(P4-T2 owns the child-node attach). `mark_skipped/2`/`mark_deferred/2` no-op
when the current docs state is `"current"`, and `mark_deferred/2` builds from
the current row, so a manual release cannot wipe `docs_commit_sha` and a later
forced no-op cannot rewind `C2` to `C1`. Tests: blocked manual job is excluded
from `pushable` until it resolves; a push during a blocked job keeps the SHA
and defers the docs. Verification: format + dev/prod compile clean; 784 tests
green (251 shared + 179 daemon + 354 server; +2); `luac -p` and all Lua specs
pass. Spec §9.2/§9.5 updated. Next: re-review, then P4-T1.

2026-11-06 — **5c third-pass review fixes.** The final re-review found no
blockers. W2: `SyncLedger.mark_pushed/1` now accepts `{node_id, pushed_sha}`
pairs and `Sync.push_batch/2` passes the snapshot SHA it encoded, so an
in-flight push stamps the SHA the server received rather than a newer local
SHA; plain IDs remain supported with a current-SHA fallback. S3:
`mark_pending/1` returns `{:skip, :already_current}` when the current node is
already current, and `DocQueue.sync/2` maps it to the skipped response, so a
concurrent success is not re-armed as pending. Test added for the pushed-SHA
stamp; the hold/guard/release tests remain green. Verification: format +
dev/prod compile clean; 785 tests green (251 shared + 180 daemon + 354 server;
+1); `luac -p` and all Lua specs pass. Next: re-review or commit, then P4-T1.

Session closed 2026-11-06 — Phase 5c is complete at `a7202db`
(`feat: Phase 5c — daemon doc API, Neovim commands, and sync hardening`),
with the handoff commit following. Working tree clean. Verification: 785 tests
green (251 shared + 180 daemon + 354 server), format clean, dev/prod compile
clean, `luac -p` and the Lua specs pass. Next session starts **P4-T1**:
`@phx-work .claude/plans/phase-5-docs/plan.md --from P4-T1`.

2026-11-06 — **Phase 5 P4-T1 (reconnect docs retry)** shipped from
`.claude/plans/phase-5-docs/plan.md`. The deferred-docs retry moved **before**
the push: `Sync.sync/2` takes `retry_docs:` and calls
`DocQueue.retry_pending/1` between `ensure_project/1` and `push_pending/1`, so
`mark_pending/1` re-arms the sync hold synchronously and the reconnect pass
cannot send the code-only `C1`. `SyncWorker.start_project/2` requests it only on
the first pass after boot or a failed pass (`last_status != :ok`) — replacing the
post-pass hook in `finish/3` — so a permanently failing job is retried once per
outage and the node still syncs code-only (D6). New
`apps/cadence_daemon/test/doc_reconnect_test.exs` proves one pushed node at `C2`
(never `C1`, `parent == [C1]`) and the failed-retry fallback. Spec §9.5 and the
plan/scratchpad execution notes updated. Verification: `mix format
--check-formatted` and `mix compile --warnings-as-errors` clean; 787 tests green
(251 shared + 182 daemon + 354 server); server suite ran against the test
Postgres on `localhost:55432`. Next: P4-T2 (already-pushed docs child node).

2026-11-06 — **Phase 5 P4-T2 (already-pushed docs child node)** shipped from
`.claude/plans/phase-5-docs/plan.md` (`@phx-full … --from P4-T2`). A node whose
SHA is on the server is never rewritten; its docs attach as a follow-up child
node. `DocQueue.docs_mode/1` replaces the old pushed guards with `:child` (any
`docs_pushed_sha` stamp — the SHA is immutable, so the docs must go to a child),
`:local` (`SyncPending` row, no stamp) and `:legacy` (neither: pulled or pre-5b,
refused); `already_synced` is gone and `POST /docs/sync` answers
`202 %{status: "queued", node_id}` for a pushed node. The child is a real node
(`git_commit_sha: C2` with git parent `C1`, `parents: [code_node.id]`,
`docs_state: :current`, `flags: [:"in-progress"]`, `pinned: false`,
`metadata["docs"]["docs_for"]`) with its own `SyncPending` row
(`SyncLedger.insert_pending!/1`, now shared with `CommitQueue`) and the session
pointer advanced to it in the same transaction; the parent keeps its SHA and
records `docs_state: :current`, `docs_commit_sha: C2`, `docs_child_id`, so
`:CadDocDiff` works on the code node and the child. Empty generations create no
child; a forced re-run reuses the recorded child. Independent review verdict
REQUIRES CHANGES (one BLOCKER: the in-place SHA write was a check-then-write
against the sync worker's stamp, which could move a pushed SHA and erase the
stamp) plus three WARNINGs; all fixed — the write is a compare-and-swap on
`json_extract(session_metadata, '$.docs_pushed_sha')` with one re-read,
`Session.docs_after/3` is a single conditional update, a pushed node with docs
disabled keeps its deferred state, the watcher stays suspended across the node
write, and `create_docs_child/5` rolls back instead of raising. Lesson captured
in
`.claude/solutions/data-integrity/doc-sha-write-vs-pushed-stamp-20261106.md`.
Spec §9.2/§9.5 updated; plan/scratchpad/run ledger updated. Verification:
`mix format --check-formatted`, dev + prod `mix compile --warnings-as-errors`,
793 tests green (251 shared + 188 daemon + 354 server). Next: P4-T3 (read-only
`docs_state` badge).

Session prepared for handoff 2026-11-06 — P4-T2 is implemented, reviewed and
verified but **not committed**: 10 tracked files are modified (`git status`)
plus the git-ignored plan/scratchpad/ledger/solution artifacts. Suggested
commit before starting cold:
`git add -A && git commit -m "feat: Phase 5 P4-T2 — docs child node for already-pushed nodes"`.
Server tests need the test Postgres on `localhost:55432` (container
`cadence-test-pg` is running).

2026-11-06 — **Phase 5 P4-T3 + P4-T4/T5 (docs badge + closeout)** shipped from
`.claude/plans/phase-5-docs/plan.md` (`@phx-full … --from P4-T3`). P4-T2 was
committed first (`d17ebd2`) after re-running the gate. Badge:
`Presentation.docs_state_label/1` / `docs_badge_class/1`;
`Portfolio.docs_child/2` requires `metadata["docs"]["docs_for"]` **and** DAG
parentage (metadata-only claims ignored), newest first, project-scoped;
`ProjectLive` renders the selected node's own state plus a `patch` link to the
docs child, and `{:nodes_pushed, …}` re-reads **only** that link (the DAG layout
is untouched, so no intro replay). CSS `.docs-badge` reuses the AA status text
tokens with hover/focus underlines. Independent review: **PASS WITH WARNINGS**;
W2 (a child pushed while the parent was open never appeared) and S1–S4 were
fixed (query-based lookup with parentage/self guards, live event refresh,
neutral tooltip, link-class assertions, hover affordance); W1 (server-created
meld nodes stay `:pending` forever) is recorded in spec §9.4/§16 and the Spec
Deltas. P4-T4/T5: §9.3 commit model, §9.5 one-node-at-`C2` wording, §9.6 worker
contract, §13 5a/5b/5c/P4 breakdown, §16 web-review + meld-node gap,
`docs/README.md` status/read order. Verification: `mix format
--check-formatted`, dev + `MIX_ENV=prod mix compile --warnings-as-errors`, 804
tests green (251 shared + 188 daemon + 365 server; +11 net). Next: P5 release
gate — optional live smoke with a real `CAD_LLM_API_KEY`, then final
review/handoff.

2026-11-06 — **Phase 6a (Docker action manifest foundation)** shipped from
`docs/phase-6-prep.md`. `Cadence.Server.Actions.Manifest` strictly parses
`actions/manifest.json` (≤ 20 actions, ≤ 32 KiB, 64-char lowercase names,
1–512-byte commands, ≤ 200-byte descriptions, control/bidi chars and duplicates
rejected, unknown keys ignored); `Cadence.Server.Actions` reads it from the
selected node's Git tree, requires a project-scoped membership, gates on
`CAD_ACTIONS_ENABLED`, and returns shape-only errors. `ProjectLive` renders a
read-only Actions panel for members (hidden for anonymous/non-members, disabled
deployments, absent/invalid manifests, and quarantined snapshots) and
re-derives it when quarantine flips or raw view toggles. Config:
`CAD_ACTIONS_ENABLED`, `CAD_DOCKER_SOCKET`, `CAD_ARTIFACT_PATH`,
`CAD_ACTIONS_MAX_MANIFEST_BYTES`, `CAD_ACTIONS_MAX_ACTIONS`. Spec
§7.1/§7.2/§8/§12.5/§12.6/§13/§16 and `docs/README.md` updated; no dependency
added (6b owns `ex_docker_api`).

**Security fix found during 6a:** `GitStore.walk_blobs/3` recursed with a
2-tuple while its parent reduce expected `{:ok, acc, count, bytes}`, so the
catch-all halted the walk after the first directory — the secret scanner
skipped every sibling file that sorted after it. The recursion now threads one
shape and `walk_blobs/3` sorts once at the top. Regression tests: a
directory-before-files walk and the project-page quarantine integration case.
Scans are now stricter (new quarantines/incidents for previously missed
content; over-cap parents block approval instead of passing truncated). Lesson:
`.claude/solutions/data-integrity/walk-blobs-truncation-20261106.md`.

Independent review verdict PASS WITH WARNINGS; all five warnings and the
actionable suggestions fixed (project-scoped membership check, live panel
refresh on quarantine/raw flips, fail-closed manifest reads, whitespace/bidi
validation, `aria-label` + command wrapping, spec contradictions, test gaps).
Verification: `mix format --check-formatted`, dev +
`MIX_ENV=prod mix compile --warnings-as-errors`, 844 tests green (252 shared +
188 daemon + 404 server; +40). Next: 6b (runner).

2026-11-06 — 6b (Docker action runner) shipped from
`.claude/plans/phase-6b-runner/plan.md`: `action_runs` schema/migration,
`Actions.Runs` lifecycle + recovery, `Actions.Docker`/`DockerEngine`
(`ex_docker_api` 1.55, API `v1.45`), staging (`walk` → scan → write), bounded
artifact collection, `Actions.TaskSupervisor`, demo socket proxy + pinned
volumes, `CAD_ACTIONS_*`/`CAD_DOCKER_API_VERSION` config, Elixir `~> 1.20`, and
spec §8/§11/§12/§13/§16 updates. Two review cycles: REQUIRES CHANGES (2
blockers — `start` mapping `%ErrorResponse{}` to success and the image
`ENTRYPOINT` not being overridden — plus build-network, proxy, volume-name, API
version, and recovery findings), then PASS. Verification: `mix format
--check-formatted`, dev + `MIX_ENV=prod mix compile --warnings-as-errors`, 898
tests green (252 shared + 188 daemon + 458 server; +54). Next: 6c (web run
experience).

2026-11-07 — **Phase 6c (web run experience)** shipped from
`.claude/plans/phase-6c-runs/plan.md` (`@phx-full`). 6b was committed first as
`962d308` after a clean gate. 6c adds manager-only Run controls on the node
action panel (membership re-read per event, rendered-quarantine reuse except in
raw view, enabled flag checked), member-only `RunLive.Index`
(`/p/:slug/runs`) and `RunLive.Show` (`/p/:slug/runs/:run_id`) with
`assign_async` loading, subscribe-after-connect, and live refresh from
`{:action_run_updated, …}`, plus `RunArtifactController` for allowlisted
downloads. `Runs.start/4` recovery moved into the task; `Runs.list/get` are
gated by `CAD_ACTIONS_ENABLED`; `Runs.read_artifact/2` accepts only an exact
recorded path on a regular file. Output renders through
`Presentation.terminal_text/1` in an escaped `<pre>` (ANSI/OSC, C0/C1, bidi
stripped; invalid UTF-8 replaced). New Presentation helpers and run/artifact
CSS; `expose` resolved as parsed-but-unhonored (members-only). Spec
§7.2/§8.2/§8.3/§8.4/§13/§16, `phase-6-prep.md`, `docs/README.md`, and
`docs/ui-notes.md` updated. Verification: `mix format --check-formatted`, dev +
`MIX_ENV=prod mix compile --warnings-as-errors`, 940 tests green (252 shared +
188 daemon + 500 server; +42 net). Independent review PASS WITH WARNINGS; the
one Medium regression (a second snapshot scan on every Run click) was fixed by
reusing the rendered answer outside raw view, and the Lows were addressed
(disabled-deployment gating, artifact render cap, download headers/404 rescue,
raw-view quarantine re-check, catch-all handlers, docs, test determinism).
Lesson:
`.claude/solutions/phoenix-issues/assign-async-key-and-controller-wildcard-list-20261107.md`.

**Handoff note:** 6c is committed at `aa28530`
(`feat: Phase 6c — web run experience`), with this handoff note as the follow-up
docs commit. Server tests need Postgres on `localhost:55432` (container
`cadence-test-pg`). Next: Phase 7 (storage engineering) planning; carry-overs
are listed in **Next**.

2026-11-07 — **Phase 7a (shared pack layer)** shipped from
`.claude/plans/phase-7a-packs/plan.md` (`@phx-full`). `GitStore.Pack`,
`Pack.Index`, `Pack.Delta`, and `GitStore.Cache` add real Git pack v2 / idx v2
write+read; `GitStore` reads loose-first then packs and exposes
`pack_objects/3`, `packs/1`, `loose_objects/1`, `invalidate_cache/1`,
`read_raw/2`, and `present_shas/2`. `Cadence.Shared.Application` owns the cache
process. Two read-only review cycles fixed O(N²) entry-end lookups (precomputed
`entry_ends`), missing fsyncs (files synced before rename, `.tmp` names),
unbounded cache (dropped CRCs, 1,024-store bound, reload-on-miss), unbounded
inflate (chunked caps), duplicate SHAs, hex path probing, and missing bulk/raw
APIs; deferred loose deletion and directory-fsync limits are recorded for 7b.
Spec §11/§13/§16, `docs/phase-7-prep.md`, and `docs/README.md` updated.
Verification: `mix format --check-formatted`, dev + `MIX_ENV=prod mix compile
--warnings-as-errors`, 994 tests green (306 shared + 188 daemon + 500 server;
+54 shared). Lesson:
`.claude/solutions/data-integrity/pack-v2-byte-format-20261107.md`. Next: 7b
(server repacker).

2026-11-07 — **Phase 7b (server repacker)** shipped from
`.claude/plans/phase-7b-repacker/plan.md` (`@phx-full`). `Cadence.Server.Storage`
runs sweep-then-pack: it invalidates the pack cache once, removes crash debris
(`tmp-*` and half-renamed `pack-*` pairs, 5 min grace), unlinks a loose object
only after `GitStore.verify_packed/2` read it through the pack and re-hashed it,
then packs the remaining loose objects in `CAD_REPACK_MAX_PACK_BYTES` batches
read via `GitStore.read_loose_raw/2` (loose-only, re-hashed, so a corrupt loose
file is skipped rather than aborting the run). `Storage.Repacker` is a
single-worker FIFO with per-project dedupe, a failure cooldown (one interval)
and a backstop that bypasses it; the cross-process fence is a transaction-scoped
`pg_try_advisory_xact_lock` and `:busy` is a skip, not a failure.
`Sync.push_nodes/2` triggers a best-effort check after commit and
`mix cadence.repack [--project <id|slug>]` runs on demand. Config:
`CAD_REPACK_ENABLED`, `CAD_REPACK_MIN_OBJECTS`, `CAD_REPACK_MIN_BYTES`,
`CAD_REPACK_INTERVAL_MS`, `CAD_REPACK_MAX_PACK_BYTES`. Spec
§12.6/§13/§16, `docs/phase-7-prep.md`, `docs/README.md`, `.env.example`
updated. Verification: `mix format --check-formatted`, dev +
`MIX_ENV=prod mix compile --warnings-as-errors`, 1023 tests green (309 shared +
188 daemon + 526 server), and a `mix cadence.repack` smoke (run 1 packs + keeps
loose, run 2 sweeps, run 3 no-op, debris removed). Two read-only reviews: PASS
WITH WARNINGS, then a second pass found 3 new warnings, all fixed (no empty-pack
call, orphan grace, content re-hash). Lesson:
`.claude/solutions/data-integrity/repack-deferred-deletion-20261107.md`. Committed
at `e6903b6` (`feat: Phase 7b — server repacker with verified deferred loose
sweep`), with this handoff note as the follow-up docs commit; working tree
clean. Next: 7c (sync existence handshake).

2026-11-07 — **Phase 7c (sync existence handshake)** shipped from
`.claude/plans/phase-7c-exists/plan.md` (`@phx-full`). New
`POST /sync/objects/exists` (bearer PAT, owner/trusted, project-scoped) answers
`%{present}` from `GitStore.present_shas/2`; invalid SHAs are refused and the
raw list is capped by `CAD_SYNC_EXISTS_LIMIT` (5000) before dedupe. The daemon
loads each node's objects once, chunks the batch's unique SHAs under the cap,
unions the answers, filters `git_objects`, and sends metadata unchanged. Any
failed chunk falls back to a full push; a 422 on a filtered push retries once
with every object. A non-positive cap disables the handshake. Spec
§10.2/§10.6/§12.6/§13, `docs/phase-7-prep.md`, `docs/README.md`, `.env.example`
updated. Verification: `mix format --check-formatted`, dev + `MIX_ENV=prod mix
compile --warnings-as-errors`, 1042 tests green (309 shared + 198 daemon + 535
server; +10). Two review passes: no blocker/high; fixed the skip-over-cap design
(now chunked), a `<= 0` chunk-size footgun, raw-cap ordering, daemon config
docs, and test fidelity, and added per-object-filter, chunking, no-retry-on-5xx,
and complete-retry assertions. Lesson:
`.claude/solutions/data-integrity/sync-existence-chunking-20261107.md`. Committed
at `a9a649d` (`feat: Phase 7c — sync existence handshake`), with this handoff
note as the follow-up docs commit; working tree clean. Next: 7d
(multi-pack/index/delta-depth verification and a demo-stack smoke).

2026-11-07 — **Phase 7d (verification/closeout)** shipped from
`.claude/plans/phase-7d-verification/plan.md` (`@phx-full`). Four verification
tests close the remaining 7d claims: (1) `git_store_test.exs` reads across two
packs plus a loose object with `invalidate_cache/1` between writes, exercising
every read primitive; (2) `pack_index_test.exs` covers all 256 fanout buckets,
asserts cumulative counts, grows the zero bucket by 64 entries, and re-asserts
lookups; (3) `pack_test.exs` hand-builds a 50-delta chain and pins the boundary
(reads at `max_depth: 50`, `:delta_chain_too_deep` at 49); (4)
`storage_repacker_test.exs` proves a run after a sweep packs only the new loose
objects and leaves the existing pack bytes untouched. Demo-stack smoke
(`docker compose up --build`): run 1 packed 29 + 36 loose objects into one pack
per project with 0 swept; run 2 verified and swept 29 + 36 loose copies; run 3
was a no-op. `Storage.stats/1` then reported `loose=0`, `packed=29/36`,
`packs=1`. A fresh VM read the same commits, trees, 5 + 3 blobs, and object
closures as the loose baseline, and the live server served `/`,
`/p/cadence-demo`, `/p/meld-review`, `/sign-in`, and all five seeded proposal
pages with the expected 200s and rendered diff paths from pack-only storage.
Spec §13 Phase 7, `docs/phase-7-prep.md`, `docs/README.md`, and this handoff
updated. Verification: `mix format --check-formatted`, dev +
`MIX_ENV=prod mix compile --warnings-as-errors`, 1046 tests green (312 shared +
198 daemon + 536 server; +4). Phase 7 is complete; the spec §13 build order
ends here. Next: the two open freshness-review suggestions in **Next**.

2026-11-07 — **Post-7d freshness follow-ups** shipped from
`.claude/plans/review-suggestions/plan.md`. `Portfolio.quarantine_status_with_source/3`
adds provenance to the quarantine answer (`{:ok, :ok | :quarantined}` for an
incident or a completed scan, `{:error, :unverifiable}` for a failed walk);
`quarantine_status/3` keeps its `:ok | :quarantined` contract. `ProjectLive`
gained `quarantine_cacheable?` and reuses a cached answer only when it is
authoritative, so a same-key incident event retries a failure-derived scan; the
regression test sets `scan_max_files` to 0, restores it, opens a high
non-blocking incident, and expects the pane to recover (verified to fail against
the old cache). `ReviewLive.Show.incident_relevant?/5` now treats any incident as
relevant before the first successful payload load, forcing one reload so a
decision-node incident arriving mid-load cannot be dropped; the pure predicate
is unit-tested. Verification: `mix format --check-formatted`, dev +
`MIX_ENV=prod mix compile --warnings-as-errors`, 1049 tests green (312 shared +
198 daemon + 539 server; +3). Review: PASS, no findings requiring a change; the
Run-click retry scope is recorded in Spec Deltas. Next: the union live smoke.
