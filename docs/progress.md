# Cadence — Progress

## Current Phase
Phase 4 — unions, proposals & review. 4a-1, 4a-2, and 4b are complete; 4b-2
(server push scan + node incidents) is next.

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
- 472 tests green (161 shared + 115 daemon + 196 server);
  `mix format --check-formatted`, `mix compile --warnings-as-errors`, and
  `MIX_ENV=prod mix compile --warnings-as-errors` clean.
- **Tooling (OpenCode)** — vendored skill checkout + restore script
  (`scripts/setup-opencode.sh`, 51 skills), project `opencode.jsonc` (mix
  formatter, destructive-command guards), AGENTS.md §12 (routing, Iron Laws,
  state/artifact mapping), `docs/opencode.md`.
- Full session-by-session history is frozen in
  `docs/archive/progress-history.md`.

## Next

1. Execute **4b-2 — server push scan + node incidents** from
   `.claude/plans/push-scan-4b2/plan.md` (approved 2026-11-05; 10 tasks across
   P0–P4; scratchpad alongside). Decisions: scan only newly inserted nodes after
   commit, synchronous capped scan, node incidents resolve by acknowledgment.
   No daemon/response/template/config changes.
2. Then **4c — review UI + incident panel + approve/reject** (must also add the
   `meld_commit_sha` ↔ `result_tree_sha` cross-check before exposing approval).
3. Then 4d (broadcast/pull + daemon convergence).

## Blocked

- (none) The Phase 4 gating decisions are resolved in spec §6.6/§6.7/§16 and
  `docs/phase-4-prep.md` §5.

## Spec Deltas / Open Items

- **Proposal result quarantine scope** (4a-2): paths are filtered + counted; a
  secret value in a *visible* result file quarantines the whole result, so a
  secret behind a hidden path name is not content-scanned. Recorded in spec
  §7.6 ("Proposal results (4a-2)"). **4c must revisit this** before rendering
  file content on the proposal page.
- Proposal result integrity: `ProposalView` diffs `meld_commit_sha` and does not
  yet assert it matches `result_tree_sha`. Approval acts on `result_tree_sha`,
  so 4c must add the check before exposing approve/reject.
- Public proposal reads are uncached: two capped blob walks plus a full regex
  scan per GET, with no rate limit. If latency matters, 4c can materialize a
  stored diff keyed by result commit.
- The public proposal page lives in the `:browser` pipeline, so its body
  includes a per-request CSRF token (session-free and cacheable output would
  need a dedicated pipeline).
- `Incidents.blocking_node?/2` exists but has no caller yet; it is wired when
  4b-2 adds the server push scan.
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
2026-11-05 — 4b complete (session A + review fixes + session B P2/P3/P4):
`Melds.propose/3` pipeline, incidents on failure, spec updated. 472 tests green.
Run artifacts: `.claude/plans/meld-worker-4b/{plan,progress}.md`,
`reviews/meld-worker-4b-triage.md`. Next: 4b-2 (push scan + node incidents),
then 4c.
