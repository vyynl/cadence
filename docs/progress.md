# Cadence — Progress

## Current Phase
Phase 4 — unions, proposals & review (planning). Phase 3 is complete.

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
- 347 tests green (121 shared + 115 daemon + 111 server);
  `mix format --check-formatted`, `mix compile --warnings-as-errors`, and
  `MIX_ENV=prod mix compile --warnings-as-errors` clean.
- Full session-by-session history is frozen in
  `docs/archive/progress-history.md`.

## Next

1. Read `docs/phase-4-prep.md`, then spec §6.5/§6.6/§13/§16.
2. Resolve the Phase 4 decisions before code:
   - proposal model/quorum and re-submission policy;
   - promotion target (`pinned` vs `functioning` vs protected marker);
   - meld validation baseline (recommended: start `in-progress`, never
     auto-promote to `functioning` without a real validator);
   - meld agent/prompt/versioning;
   - proposal visibility (public vs authenticated);
   - pin propagation to daemons.
3. Start **4a — proposal model/API**. Do not build 4b/4c review UI before the
   proposal and meld backends exist.

## Blocked

- Phase 4 decisions above gate implementation. No other blockers.

## Spec Deltas / Open Items

- Web pinning is server-side only; the sync protocol does not propagate pinned
  flags to daemons. See spec §16.
- Proposal model, proposal visibility, and meld validation are open decisions
  (spec §16); see `docs/phase-4-prep.md`.
- Syntax highlighting remains deferred; file content is escaped plain code.
- Public `broken`/`sandbox` nodes and snapshots are visible; revisit if that
  proves undesirable.
- Secret filtering is best-effort, not a guarantee. Per-project overrides and
  reveal auditing are deferred; owners must rotate leaked secrets.
- Unknown project pages render HTTP 200 with a not-found view (LiveView mount
  cannot set 404 after render); revisit if search-engine semantics matter.
- `Project.visibility`/publishing is deferred; all projects are public by
  default.

## Last Updated
2026-10-24 — Phase 3 closed out; Phase 4 planning prepared in
`docs/phase-4-prep.md`. Completed-phase docs archived under `docs/archive/`.
No code changed this session; 347 tests remain green.
