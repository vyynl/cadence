# Cadence — Progress

## Current Phase
Phase 4 — unions, proposals & review is **complete**, as is the UI styling &
freshness pass (4e). **Phase 5 — documentation automation**: 5a (shared
primitives), 5b (daemon doc worker + commit integration), 5c (daemon API +
Neovim commands), and **P4-T1 (reconnect docs retry) are complete**. Both review
passes are fixed (legacy pushed-SHA guard, held-node release, already-current
skip, doc-diff wrap, plus the manual-sync hold, `mark_current` pushed guard,
conditional release, pushed-SHA stamp, and `mark_pending` current no-op). The
next slice is **P4-T2** (already-pushed docs child node), followed by P4-T3..T5
(read-only badge, spec/docs closeout).

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

**Immediate step:** start **P4-T2 (already-pushed docs child node)** from
`.claude/plans/phase-5-docs/plan.md`. P4-T1 shipped: the reconnect retry runs
before the push, so a deferred job that succeeds on reconnect reaches the server
as one node at `C2` (see
`.claude/plans/phase-5-docs/reviews/phase-5-docs-5c-triage.md` for the earlier
guards).

- P4-T2 — already-pushed fallback: create a docs child node
  (`parents: [code_node.id]`, `docs_state: :current`,
  `metadata["docs"]["docs_for"] = code_node.id`) instead of rewriting the pushed
  SHA; `:CadDocSync` still reports `already_synced` for a pushed node until
  then.
- P4-T3 — read-only `docs_state` badge in `ProjectLive`'s inspector
  (`Presentation` helper + LiveView tests; server tests need Postgres).
- P4-T4/P4-T5 — spec §9.3/§9.4/§9.5/§9.6 and §13 closeout; `docs/README.md`
  status.

**P4-T2 prep (noted during P4-T1).** Four guards currently refuse a pushed node
and must all learn the child-node path, not just `DocQueue.sync/2`:

1. `DocQueue.run/2` — `pushed?(node) -> :drop` (a forced job never runs).
2. `DocQueue.sync/2` — `check_pushed/1` returns `{:skip, :already_synced}`.
3. `DocQueue.resumable_nodes/1` — `not pushed?(node)`, so `rehydrate/0` and
   `retry_pending/1` ignore it.
4. `DocQueue.mark_current/5` — returns `{:error, :pushed}` (terminal) when a
   push lands mid-job; that is the mid-run variant of the same fallback.

Shape to implement: run the job against the pushed SHA as `C1`, write `C2` with
git parent `C1`, then **insert a new node** (`git_commit_sha: C2`,
`parents: [code_node.id]`, `docs_state: :current`,
`metadata["docs"] = %{code_commit_sha: C1, docs_commit_sha: C2, docs_for:
code_node.id, ...}`), with its own `SyncPending` row written in the node
transaction (mirror `CommitQueue.insert_sync_pending!/1`, currently private).
Notes/decisions to settle first:

- **Session pointer.** Advance it to the child (`Session.commit_after/2`-style):
  the working tree now holds docs, so leaving the anchor on `C1` makes a late
  watcher event compare the `C1` tree to the docs tree and create a duplicate
  node (`skip_unchanged` only matches when the anchor's tree equals disk).
- **Idempotency.** Look up an existing child by `metadata["docs"]["docs_for"]`
  before creating one; a repeated `:CadDocSync` must not fan out duplicates.
- **Manual sync must not re-hold the pushed parent.** `DocQueue.sync/2` calls
  `mark_pending/1` + `SyncLedger.enqueue/2` before the cast; for a pushed node
  that re-creates a `SyncPending` row and re-pushes the same SHA. The child (not
  the parent) should be marked pending/queued.
- **Response shape.** `{:queued, node_id}` is answered before the model runs, so
  the child id does not exist yet. Decide: return the code node id and let the
  Neovim notification say "docs queued", or add a `kind`/`docs_for` field.
  `cadence.nvim/lua/cadence/doc.lua` maps `already_synced` today and needs the
  new case if the skip goes away.
- **Flag.** The child is a real commit created by the daemon, not a user
  session; `[:"in-progress"]` (like a meld approval) vs `:functioning` (the
  code it documents may not be) needs a call. `pinned` should stay false.
- **`DocDiff.build/2`** already works for the child when its docs metadata
  carries `code_commit_sha` (it diffs `C2.tree` against `C1.tree`); the
  first-parent fallback would also resolve, but set it explicitly.

**Integration contract:** `LLM.Docs.build_prompt/4` returns
`{:ok, prompt, %{writable_paths, read_only_paths}}`; `DocQueue` passes
`read_only_paths` to `parse/3`. A node's docs commit is
`session_metadata["docs"]["docs_commit_sha"]` (absent with `"empty": true` for
a no-op generation); the code commit is
`session_metadata["docs"]["code_commit_sha"]`. `DocQueue.enqueue(force: true)`
still supports a direct forced run on a `:skipped`/legacy node by falling back
to `node.git_commit_sha`; `POST /docs/sync` gates that behind a `SyncPending`
row (the local proof the node is unpushed) and reports `already_synced` for a
stamped pushed node, `already_current` for generated docs, and `legacy`
otherwise (P4-T2 owns the child-node fallback). Reconnect ordering:
`Sync.sync/2` `retry_docs: true` → `DocQueue.retry_pending/1` (re-arms the hold
synchronously) → `push_pending/1`; `SyncWorker` asks for it only on the first
pass after boot or a failed pass.

Carry-over (small, not blocking Phase 5):

1. **Union live smoke** — drive `:CadUnion` against the demo stack once
   (`docker compose up`, `docs/demo.md`) and record the result; the Neovim
   submit is the one 4d-3 surface without a live run.
2. **Two open review suggestions from the freshness review:**
   - `ReviewLive.Show`: an incident on the decision node that arrives while the
     review payload is still loading is dropped (`decision_node_ids/1` returns
     `[]` before the async completes) and Approve stays enabled until reload
     (it still fails closed on click).
   - `ProjectLive`: the quarantine cache is reused for a `:quarantined` answer
     derived from a failed `walk_blobs`; reuse only `:ok` and re-derive a
     failure-derived answer.
3. **Optional `:CadProposals` surface** for the union token returned to Neovim.
4. **Manual styling check** (optional): `docker compose up`, then `/`,
   `/p/cadence-demo`, `/p/cadence-demo/reviews`, one pending proposal, and
   `/proposals/<token>` at wide and narrow widths in light and dark. There are
   no browser tests; 4e verified server-rendered markup and CSS only.

**Spin-up:** `@phx-work .claude/plans/phase-5-docs/plan.md --from P4-T1`.

## Blocked

- (none) The 5c review passes are complete; the Phase 4 gating decisions are
  resolved in spec §6.6/§6.7/§16 and `docs/phase-4-prep.md` §5.

## Spec Deltas / Open Items

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
- **Doc commit SHA gating/fallback (5b → P4)** — selection gating is
  implemented and tested, and `mark_pushed/1` stamps a top-level
  `session_metadata["docs_pushed_sha"]` (covering `:skipped` nodes) so
  `rehydrate/0`, `retry_pending/0`, and the job runner never rewrite an
  already-pushed SHA. A forced no-op run keeps the previous `C2`. P4-T1 closed
  the reconnect hole by running the retry *before* the pass pushes, so a
  deferred job on an unpushed node still gets its `C2` onto the server as one
  node. P4-T2's follow-up docs child node remains open for a node that was
  genuinely pushed before its docs resolved (mid-job push, or a manual sync
  after a code-only push): `:CadDocSync` / `POST /docs/sync` reports
  `skipped: "already_synced"` and cannot generate docs for it (the queue drops
  it).
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
  resolved `node_id`; the skip reasons are `already_synced`, `disabled`,
  `no_schema`, and `invalid_schema`. Manual sync respects `CAD_DOCS_ENABLED`
  (spec §9.2) instead of overriding it. `GET /docs/diff` also defaults
  `node_id` to the anchor, returns `400` without `project_id`, `404` for an
  unknown node/commit, and `409` for no docs commit or no schema.
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
