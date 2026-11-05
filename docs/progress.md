# Cadence — Progress

## Current Phase
Phase 4 — unions, proposals & review. 4a-1, 4a-2, 4b, 4b-2, 4c-1, 4c-2 and the
**demo stack** are complete; 4c-3 (incident panel) is next.

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
- 551 tests green (161 shared + 115 daemon + 275 server);
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

1. Execute **4c-3 — incident panel** from `.claude/plans/review-ui-4c/plan.md`
   (P2-T9..T11), then P3 docs. P2 adds `Incidents.list_open/2` to
   `ReviewLive.Index` with severity/kind/title/date, subject links and a
   redacted details summary, plus a `resolve_incident` event that re-checks
   `can_decide?`, passes `verify:` for proposal-linked incidents (a remaining
   secret is `:still_risky` → "reject and re-propose") and acknowledges node
   incidents. Run `/phx-full .claude/plans/review-ui-4c/plan.md` starting at P2.
   Scratchpad alongside; ledger in `.claude/plans/review-ui-4c/progress.md`.
2. Then 4d (broadcast/pull + daemon convergence).

UI observations between sessions go in `docs/ui-notes.md`. One styling pass
over the portfolio, project, review and incident surfaces is best scheduled
after 4c-3 (so the incident panel is styled in the same pass), unless a demo
needs polish sooner.

## Blocked

- (none) The Phase 4 gating decisions are resolved in spec §6.6/§6.7/§16 and
  `docs/phase-4-prep.md` §5.

## Spec Deltas / Open Items

- **Proposal result quarantine scope** (4a-2): paths are filtered + counted; a
  secret value in a *visible* result file quarantines the whole result, so a
  secret behind a hidden path name is not content-scanned. Recorded in spec
  §7.6 ("Proposal results (4a-2)"). **4c-3 must revisit this** before rendering
  file content on the proposal page (4c-2 still renders paths only).
- **Approval integrity is uncapped (4c-1)** — `Proposals.result_integrity/2`
  walks the result with `GitStore.objects_from/2` (no limits, as the approved
  plan specifies), while the reviewer's diff is capped by
  `Portfolio.scan_limits/0`. A result above those caps therefore renders as
  "too large" but is still approvable, and the walk runs inside the decision
  transaction. **4c-2 made this hot**: the review page now runs that walk on
  every load (in its async task) alongside two capped walks. Fix before 4d by
  checking under the scan caps and mapping overflow to its own integrity error.
- **The UI blocks unreviewable results, the context does not (4c-2)** — the
  review page hides Approve when `ProposalView.result/3` returns
  `{:error, :too_large | :missing_objects}` or a quarantined result, but an
  injected event still reaches `Proposals.approve/3`, whose integrity check only
  covers the result commit/tree. If a result commit verifies while the first
  parent is missing, approval would succeed with no diff ever shown. Accepted
  for now (self-inflicted, `can_decide?` only); closing it means teaching
  `result_integrity/2` about parent availability.
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
- **Review-page identities (4c-2)** — the plan asks for proposer/reviewer
  email; §7.2 gates the member list (roles) to owner/trusted. The page now shows
  emails only to `can_manage?` (owner/trusted) and a display name to viewers.
  Record the review-page identity rule in §7.2 during P3-T2.
- **Review-page freshness (4c-2, Iron Law 5)** — `isolated?` and `can_decide?`
  are recomputed on every `handle_params` and after every decision, but nothing
  pushes external changes: an incident opened while the page is open leaves the
  Approve control looking enabled until reload. The event path re-reads the
  membership and the context re-checks incidents, so a stale click fails closed
  (`:blocked | :forbidden`). There is no incident broadcast to subscribe to;
  P2 should add one when it owns the panel.
- **No entry point to the review hub (4c-2)** — nothing links to
  `/p/:slug/reviews` from `ProjectLive`; reviewers must know the URL. Add a
  member-only nav link (P3).
- **Render duplication (4c-2)** — the review page repeats the public proposal
  result block (`proposal_html/show.html.heex`) with its own isolation sentinel,
  and `kind_title`/`format_flags`/`format_time` are now duplicated across four
  web modules. The public template is frozen by the plan; extract a shared
  result component plus a format module when the public page next changes.
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
- **Cached `quarantine` assign (4b-2 discovery)** — `ProjectLive.handle_params/3`
  reuses the previous `:quarantined` assign when the selected node id is
  unchanged, so an incident opened while a member is viewing is not reflected
  until they select another node (a fresh mount always recomputes). 4c should
  drop the short-circuit or invalidate on incident changes via PubSub. Captured
  in `.claude/solutions/liveview-issues/quarantine-assign-cache-project-live-20261105.md`.
- **Push-scan alerting is best-effort (4b-2)** — a failed incident insert never
  fails the push; the read-path scan still quarantines the content, but the
  alert is lost until the next event.
- Proposal JSON representation, line-level diffs, file content, and parent
  selection are deferred to 4c.
- `format_time/1` and `format_flags/2` now exist in three web modules
  (`ProjectLive`, `DAG`, `ProposalHTML`); extraction is deferred tech debt.
- Web pinning is server-side only; the sync protocol does not propagate pinned
  flags to daemons. Approval will set `pinned`, but daemons will not see it
  until 4d resolves propagation. See spec §16.
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
- Concurrent duplicate meld proposals for the same parents are accepted (two
  LLM calls, two proposals) until 4d adds queue dedupe.
- Meld validation syntax-checks only `.ex`/`.exs`; other languages are
  reviewer-checked in 4c.
- `result_metadata` is server-owned and never cast; surfacing it in the review
  UI is optional 4c work.

## Last Updated
2026-11-05 — demo stack shipped end to end (P0–P3 in one session at the user's
request): compile-gated demo password auth with a prod guard, `DemoSeed` + mix
task, a dev-mode Docker image and compose stack, header navigation with
sign-in/out and a member-only Reviews link, `docs/demo.md`, and spec updates.
Verification: format/compile clean in dev and prod (prod has no `:demo`
strategy), 551 tests green, and the compose smoke passed (`/health`, `/`, both
demo projects, a proposal token, `/sign-in`, anonymous reviews redirect, demo
sign-in session). Two bugs fixed during the run: `sign_out_route/3` takes the
path before opts, and the seed task now disables the endpoint so it can run
inside an already-running container. An Ecto challenge review then found and
fixed 6 issues: token revocation used the bare UUID instead of Ash's
`user?id=<uuid>` subject (medium), seeding raced on unique indexes, the seed was
non-atomic, `hashed_password` accepted non-bcrypt values, and the review-queue
sort lacked a covering index. UI observations now have a durable home in
`docs/ui-notes.md`; the intended next slice is 4c-3 (incident panel).
