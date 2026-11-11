---
description: Supervise the audit-100 plan — one child session per item, integrate, gate, review, and commit on approval
agent: build
---

You are the **supervisor** for the Cadence audit-100 cleanup. You own planning,
integration, verification, review, approval, and commits. Child sessions do the
per-item implementation with fresh context.

Arguments: `$ARGUMENTS`

Interpret:
- **empty** → every item in `docs/audit-100-plan.md`, in the order below.
- **`quick`** → the cheap subset: `A2 P1 P2 S1 S2 T1 T2 D1`.
- **IDs** (`T1 T2`, `P1,P2`, …) → only those items.
- **`--auto-approve`** → commit each item after a clean gate without asking
  (still never push, never rewrite history).
- **`--plan-only`** → stop after the run plan and its approval.
- **`--max-items N`** → stop after N committed items (default 6).

## Invariants (do not violate)

- Follow `AGENTS.md` in full. Read `docs/progress.md` first.
- **Never** push, force-push, rewrite history, or commit `.claude/`.
- **Never** add or bump a dependency without updating spec §11 and getting
  explicit user approval first (`S1`, `D1`, `D2` need this).
- **Never** change `CAD_*` names, public routes, or schema without spec text.
- **Never** run `mix ecto.drop/reset`, and never mount Docker changes.
- One item = one focused change = one commit. No bundling unrelated items.
- Mutating child sessions run **sequentially in the main working tree**. Do not
  use worktrees or parallel writers: `mix.exs`, `config/`, `docs/spec.md`, and
  the endpoint/router overlap, and the test suite shares one Postgres database.
  Parallelism is for **read-only** research only.
- Small integration fixes (format, alias, typo) you may make yourself. Anything
  larger goes back to the same child session via its `sessionID`.

## 0. Preflight (stop if any fails)

1. Read `docs/progress.md`, `docs/audit-100-plan.md`,
   `docs/audit-2026-11-11.md`, `docs/spec.md` §11/§13/§16, and `AGENTS.md`.
2. `git status --porcelain` must be empty. If not, ask the user to commit/stash
   and stop.
3. Postgres must be reachable on `localhost:55432`:
   `docker ps | grep 55432`. If absent, start the documented container:
   `docker run --rm -d --name cadence-test-pg -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=cadence_test -p 55432:5432 postgres:16-alpine`
   (reuse if it already exists).
4. Baseline gate: `mix format --check-formatted`,
   `mix compile --warnings-as-errors`, `mix test`. Record the per-app counts.
   If the baseline is red, stop.

## 1. Run plan (approval gate)

Build and present a table: item, why (rubric points), expected files, new
dependency?, risk, and wave. Default waves:

1. `T1` sleeps, `T2` coverage threshold — stabilize tests first.
2. `S1` Sobelow, `S2` `/sync` rate limit, `S3` CSP — security.
3. `P1` users batching, `P2` preview query, `P3` proposal cache.
4. `A2` proposal-result component, `A1` `ProjectLive` split.
5. `D1` `mix_audit`, `D2` `libgraph` bump.
6. `T4` CI workflow, then the exemption notes (`A3`, `P4`, `T3`), then the
   final audit. `T4` comes last so the workflow can reference Sobelow and
   `deps.audit` that earlier waves added.

Mark dependency items explicitly: "adds a dev/test dependency + spec §11 row —
needs approval before the child starts."

Use the `question` tool: **Approve run plan / Adjust / Plan only / Stop**.
Do not implement anything before approval (unless the user already passed
`--plan-only`, in which case stop here).

## 2. Per-item loop

For each item in wave order:

### 2a. Dispatch one child session

Call `subagent` with a fresh session. Use `elixir-pro` for Elixir code,
`general` for mix/CI/docs/tooling, `explore` for read-only discovery, and never
more than one writer at a time. The brief must contain:

- Repo root: `/home/vyynl/Programming/projects/cadence`.
- The exact item text from `docs/audit-100-plan.md` plus its acceptance
  criteria.
- Required reading: `AGENTS.md`, `docs/progress.md`, the relevant spec section,
  and the relevant skill (`@phx-quick`, `@ecto-patterns`, `@liveview-patterns`,
  `@testing`, `@security`, …).
- **Allowed files** (be specific) and "do not touch anything else".
- Hard rules: no commit, no push, no new deps, no `.claude/` edits, no
  `docs/progress.md` edits, no full-suite run, no destructive commands.
- Focused tests to run, and the exact acceptance check.
- Report shape: files changed, tests run + counts, evidence, risks, open
  questions, proposed spec/docs delta.
- "If you hit a blocker, stop and report it; do not improvise around the
  boundary."

### 2b. Integrate and verify

1. Review `git status` and `git diff`: reject unrelated edits, debug leftovers,
   secrets, or `.claude/` files.
2. Run the focused tests yourself, then the full gate:
   `mix format --check-formatted`,
   `mix compile --warnings-as-errors`,
   `MIX_ENV=prod mix compile --warnings-as-errors`,
   `mix test`.
3. Run the item's acceptance checks from the plan (e.g. `mix xref graph`,
   `mix sobelow --exit medium`, `mix deps.audit`, `mix test --cover`).
4. If it fails, send precise findings back to the **same** child session
   (`subagent` with `sessionID`). Max 3 attempts per item, then mark BLOCKED.

### 2c. Read-only review

Before every commit, launch a `phoenix-reviewer` subagent (read-only) over
`git diff` with: the item, the acceptance criteria, and the spec section.
Findings become fixes (return to 2a/2b); review never edits. Re-review after
fixes only if a blocker/high finding changed behavior.

### 2d. Approval and commit

Present one compact block: item, what changed (files), gate result + counts,
review verdict, risk, and the proposed commit message. Ask via `question`:
**Approve commit / Approve all remaining / Revise / Stop**. Skip the ask only
under `--auto-approve`.

On approval:
- `git add` the **specific paths** (never `git add -A`).
- Conventional message, e.g. `perf(accounts): batch users_by_ids (audit P1)`,
  with a body listing verification counts.
- Commit. Do not push. Report the hash.

Per item, also update the run ledger at
`.claude/plans/audit-100/progress.md` (append-only: seq, phase, item, attempt,
outcome, evidence). Never let it become a second source of truth for the repo —
`docs/progress.md` is still the handoff.

## 3. Cross-cutting rules per wave

- `docs/progress.md` is updated by **you**, not children, at wave boundaries
  and at the end (Done / Next / Blocked / Spec Deltas / Last Updated).
- Spec edits belong to the item that requires them; keep §11/§12.6 rows in the
  dependency/security commits.
- Exemptions `A3` (Phoenix compile cycle), `P4` (streams), `T3` (Mox) are
  **documentation only** — write one-line rationales into the audit method;
  do not add Mox or restructure the endpoint/router.
- After each wave: run the full suite, `mix format --check-formatted`, and
  refresh `/tmp/opencode/audit-100-gate.log` with the results. Commit only
  green waves.

## 4. Final audit (after the last approved commit)

1. Re-run the five tracks using `@phx-audit` (or the method and commands in
   `docs/audit-2026-11-11.md`): architecture, performance, security, tests,
   dependencies. Include the exemption rationales.
2. Write `docs/audit-<YYYY-MM-DD>.md` with the score, per-track evidence, and
   remaining deductions. Update `docs/audit-100-plan.md` to mark shipped items
   (or state what remains).
3. Update `docs/progress.md` per AGENTS §2 and point **Next** at whatever is
   left (product 9d/9e or audit items).
4. Present the docs diff + final gate for approval; commit docs separately
   (`docs: refresh the audit after the 100-plan slice`).
5. Stop. Do not start new work after the handoff.

## 5. Reporting

For every item and at the end, report:

| Item | Status | Commit | Gate | Review |
|---|---|---|---|---|

Then: total tests, audit score before → after, remaining items, and any
blocker with the exact resume command (`/audit-100 <IDs>`). If you stop early,
state the resume point and the ledger path. Never claim a gate you did not run.
