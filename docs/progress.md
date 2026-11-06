# Cadence — Progress

## Current Phase
Phase 4 — unions, proposals & review is **complete** (4a-1, 4a-2, 4b, 4b-2,
4c-1, 4c-2, 4c-3, 4d-1, 4d-2, 4d-3 and the demo stack). The next slice is the
UI styling/freshness pass, then Phase 5 (doc automation).

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
- 596 tests green (161 shared + 125 daemon + 310 server);
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

1. UI styling/freshness pass: incident panel, review pages, portfolio/project
   surfaces (`docs/ui-notes.md`), the still-open PubSub freshness item (an
   incident/proposal opened elsewhere does not reach an open socket), and the
   cached quarantine assign in `ProjectLive`.
2. Then Phase 5 — documentation automation (spec §9, §13): doc schema parsing,
   the doc agent with its own limiter, deferred docs when offline, and
   `:CadDocDiff`/`:CadDocSync` (both still stubs).
3. Optional polish: a `:CadProposals`/notification surface for the returned
   proposal token (not in spec; discuss before adding).

## Blocked

- (none) The Phase 4 gating decisions are resolved in spec §6.6/§6.7/§16 and
  `docs/phase-4-prep.md` §5.

## Spec Deltas / Open Items

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
- **Review-page freshness (4c-2/4c-3, Iron Law 5)** — `isolated?` and
  `can_decide?` are recomputed on every `handle_params`, after every decision,
  and after every incident resolution, but nothing pushes external changes: an
  incident opened while either page is open leaves controls looking usable
  until reload. The event paths re-read the membership and the context
  re-checks incidents/roles, so a stale click fails closed
  (`:blocked | :forbidden`). 4c-3 owns the incident panel and deliberately adds
  no PubSub (plan Iron Law table: "No PubSub subscription added in 4c"), so
  incident broadcasts plus subscriptions are a 4d item.
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
- Proposal JSON representation and parent selection are not planned; line-level
  diffs and file content remain deferred to the UI pass.
- `format_time/1` and `format_flags/2` now exist in three web modules
  (`ProjectLive`, `DAG`, `ProposalHTML`); extraction is deferred tech debt.
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
