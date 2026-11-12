# Path from 87 to 100 — audit gap-closing plan

**Baseline:** `docs/audit-2026-11-11.md` (87/B at the moment the findings were
written). Two P1s were fixed in the same session, so the effective re-score is
**89/B**: Tests 86 → 96 (the flake is fixed) and Dependencies 90 → 95 (the
retired package is fixed; no CVE scanner yet).

**What "100" means here:** every deduction in `phx-audit`'s rubric is either
paid for or explicitly recorded as a method exemption. It is a rubric
satisfaction exercise, not a product goal. The items below are ordered by real
value first; the last section lists the rubric-only items this project should
*not* chase blindly.

Weighting: architecture 20%, performance 25%, security 25%, tests 15%,
dependencies 15%. Overall = sum(score × weight).

## Gap table

| Track | Current | Points on the table | Work |
|---|---|---|---|
| Architecture | 85 | 15 | Split `ProjectLive`; extract the duplicated proposal-result markup |
| Performance | 85 | 15 | Batch `users_by_ids/1`; one-query `preview_node/1`; cache the public proposal render |
| Security | 88 | 12 | Sobelow; `/sync/*` rate limit; CSP |
| Tests | 96 | 4 | Remove fixed `Process.sleep`s; explicit coverage threshold; CI |
| Dependencies | 95 | 5 | `mix_audit`; `libgraph` 0.17 DAG regression pass |

Doing all of it yields 100 under the rubric. A sensible subset (A1, P1, S2,
T1, D1) lands at ~97 and costs about half the effort.

## Architecture (85 → 100)

**A1. Split `ProjectLive` (the 19-outgoing-dependency hotspot).**
- Current: `project_live.ex` (≈800 lines) owns the DAG, tree, blob, README,
  actions, raw view, quarantine cache, and events.
- Target: extract the selected-node pane into `ProjectLive.NodePane` (or a
  stateless `Components.NodePane`) and keep `ProjectLive` for routing/events.
  Aim for a fan-out under 5 contexts per module.
- Acceptance: `mix xref graph --format stats` shows `project_live.ex` outgoing
  edges ≤ 8 (from 19); the LiveView tests and the project page smoke still pass.
- Effort: 1 session.

**A2. Extract the proposal-result component.**
- `proposal_html/show.html.heex` and `review_live/show.ex` render the same
  file-level result with two isolation sentinels (recorded in
  `docs/progress.md`). Extract one `Components.ProposalResult` and call it from
  both.
- Acceptance: the two surfaces render byte-identical result blocks for the same
  payload; both existing test suites pass; the duplication note is removed from
  `docs/progress.md`.
- Effort: half a session.

**A3. Record the compile-cycle exemption.**
- One compile cycle (`endpoint.ex` ↔ `router.ex`) is Phoenix's normal shape.
  Document it in the audit method rather than restructuring the framework
  wiring. If the rubric is applied literally, that cycle is -10; the honest
  answer is "accepted framework cycle".
- Effort: none (documentation).

## Performance (85 → 100)

**P1. Batch `Accounts.users_by_ids/1`.**
- `accounts.ex:45-52` runs one `Ash.get/3` per member. Replace with one
  `Ash.read(User, query: filter(id in ^ids))` and `Map.new/2`.
- Acceptance: the member panel test still renders names/roles; a unit test
  proves one query for N ids (assert with a query counter or `Ash.read` mock).
- Effort: 1 hour.

**P2. One-query `Portfolio.preview_node/1`.**
- Resolve pinned → functioning → newest in one `ORDER BY` (e.g. order by
  `pinned DESC, (functioning = ANY(flags)) DESC, created_at DESC, id DESC`
  with `LIMIT 1`).
- Acceptance: the preview precedence tests (pinned, functioning, newest) pass.
- Effort: 1 hour.

**P3. Cache the public proposal render.**
- Two capped blob walks + a secret scan per `GET /proposals/:token`. Store the
  rendered result (or the diff payload) keyed by `meld_commit_sha`/
  `result_tree_sha` with a short TTL or on creation, and invalidate on
  approval/rejection.
- Acceptance: the first request walks once; subsequent requests hit the cached
  payload; the filtering/quarantine tests still pass.
- Effort: half a session.

**P4. Document the "streams" exemption.**
- The DAG is a whole-graph SVG layout, not a scrolling list; the review queue
  is capped at 50 and run history/artifacts are paged in the context. Streams
  add nothing here. Record the exemption in the audit method (the "LiveView
  streams" rubric line).

## Security (88 → 100)

**S1. Add Sobelow as a dev-only tool.**
- Add `{:sobelow, "~> 0.18", only: [:dev, :test], runtime: false}` to the
  server's deps **and a spec §11 dependency row** (the rule in AGENTS.md §4).
  Run `mix sobelow --exit medium` in the gate/CI (from `apps/cadence_server`;
  the umbrella root refuses).
- Acceptance: no medium+ findings; the audit records the command and output.
- Effort: 1 hour.

**S2. Rate-limit `/sync/*`.**
- Add a Hammer plug (per-token or per-IP) in the `:api` pipeline with a
  generous default (e.g. 300 requests/minute, configurable via a new
  `CAD_SYNC_RATE_LIMIT*` key in `runtime.exs` + `.env.example` + spec §12.6).
  Keep the meld limiter as the inner, per-project bound.
- Acceptance: a request-test shows 429 + `Retry-After` past the limit and 200
  under it; the meld limiter tests still pass.
- Effort: half a session.

**S3. Add a Content-Security-Policy.**
- Either move the few inline styles/scripts behind nonces/hashes or set a
  `default-src 'self'` CSP with the required exceptions (LiveView needs
  `connect-src` for websockets). Add it in the endpoint or a plug after
  `put_secure_browser_headers`.
- Acceptance: LiveView pages (project, review, runs) load with no CSP console
  errors in the headless smoke; the CSP header is asserted in a controller
  test.
- Effort: half a session.

**S4. Keep the existing guarantees.**
- No `String.to_atom/1` on input, no `raw/1` on untrusted content, secrets in
  env only, authorization re-checked in every mutating event. These are already
  clean; re-assert them in the audit.

## Tests (96 → 100)

**T1. Remove fixed sleeps.**
- 35 `Process.sleep` calls remain, concentrated in daemon tests. Replace each
  with the existing `eventually/2`/polling helper or a message barrier. Do not
  rewrite tests that are already stable unless the file is touched anyway.
- Acceptance: `grep -rn "Process.sleep" apps/*/test` returns only deliberate
  debounce windows with a comment, or zero; the suite stays green twice.
- Effort: 1 session.

**T2. Explicit coverage threshold + CI.**
- `mix test --cover` currently exits 3 on Mix's default 90% threshold
  (84/82/89). Configure `test_coverage: [summary: [threshold: 80]]` in the
  umbrella root (or per app) and add the command to CI.
- Acceptance: `mix test --cover` exits 0; the threshold is documented.
- Effort: 1 hour.

**T3. Record the Mox exemption.**
- AGENTS.md §8 explicitly forbids Mox in favour of injected test modules
  (`TestMeldLLM`, `TestDocsLLM`, `FakeDocker`). The "verify_on_exit! in Mox
  tests" rubric line does not apply; record the substitution in the audit
  method instead of adding Mox.
- Effort: none (documentation).

**T4. Add CI.**
- One workflow: `mix format --check-formatted`, dev+prod compile with
  `--warnings-as-errors`, `mix deps.get`, Postgres service on 55432,
  `mix test`, `mix test --cover`, `mix hex.audit`, `mix sobelow` (from
  `apps/cadence_server`), and `mix deps.audit --ignore-file .mix_audit.ignore`
  from the umbrella root.
- Guard the CVE scan against a silent pass: mix_audit reads a git clone at
  `~/.local/share/elixir-security-advisories-mirego` and ignores clone/pull
  failures, so assert it is populated after the run —
  `find ~/.local/share/elixir-security-advisories-mirego/packages -name '*.yml' -print -quit`
  must print a path.
- Acceptance: a PR runs the gate; the badge/link is in the README.
- Effort: half a session (plus operator setup for the runner).

## Dependencies (95 → 100)

**D1. Add a CVE scanner.**
- Add `{:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}` (spec §11
  row) and run `mix deps.audit --ignore-file .mix_audit.ignore` from the
  umbrella root in CI. `hex.audit` stays for retirement.
- Acceptance: `mix deps.audit --ignore-file .mix_audit.ignore` exits 0 when
  run from the umbrella root; any documented ignore is by exact advisory ID
  and time-boxed (spec §16). The bare command exits 1 (2.1.5 has no
  auto-discovery) and an app-local run scans no lockfile.
- Effort: 1 hour.

**D2. Bump `libgraph` to 0.17.1.**
- The constraint is `~> 0.16.0`; 0.17.1 exists. Bump it and run the DAG tests
  (`graph_test.exs`, `dag_layout` tests, the project page) to prove the graph
  APIs are unchanged.
- Acceptance: full suite green; `mix hex.outdated` shows no "update possible"
  for the runtime set (patch-level noise excluded).
- Effort: 1 hour.

**D3. Keep `mix deps.unlock --check-unused` clean and the lock committed.**
- Already true; add it to CI.

## Suggested order and budget

| Step | Work | Gain | Session |
|---|---|---|---|
| 1 | T1 + T2 + T4 (tests/CI) | Tests 100, protects everything else | 1 |
| 2 | S1 + S2 + S3 (security) | Security 100 | 1 |
| 3 | P1 + P2 + P3 (performance) | Performance 100 | 1 |
| 4 | A1 + A2 (architecture) | Architecture 100 | 1–2 |
| 5 | D1 + D2 (dependencies) | Dependencies 100 | 1 |
| 6 | Re-run the audit method, update `docs/audit-*.md` | 100/B→A | 1 hour |

**Do not do:** add Mox to satisfy a rubric line; replace the capped queues with
streams that buy nothing; break the Phoenix endpoint/router compile cycle;
add CI *and* keep running the full suite twice by hand (pick one source of
truth).

## Acceptance for "100"

- The five track reports are regenerated with the same commands.
- Overall weighted score is 100, or every remaining deduction is listed as a
  documented exemption with a one-line rationale.
- `docs/audit-100-plan.md` (this file) is updated or replaced with the new
  summary, and `docs/progress.md` points at it.
