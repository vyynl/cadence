# Cadence Docs

`docs/spec.md` is the canonical contract. If a design question is not answered
there, resolve it in the spec (or add it to §16) before implementing.

## Read order

1. `progress.md` — current phase, summary, next step, blockers.
2. `phase-7-prep.md` — current phase brief.
3. `spec.md` — the relevant sections for the task.

Completed-phase briefs and the full Phase 1–3 log live in `archive/`; they are
history, not current instructions.

## Current status

| Phase | Status |
|---|---|
| Phase 1 — local daemon, commits, DAG picker, AI messages | Complete |
| Phase 2a — DAG structure, Neovim picker, diffs | Complete |
| Phase 2b — cloud sync, auth, preferences, notifications | Complete |
| Phase 3 — web UI & portfolio | Complete |
| Phase 4 — unions & review | Complete |
| UI styling & freshness pass (4e) | Complete |
| Phase 5 — doc automation | Code complete (5a shared primitives, 5b daemon worker, 5c daemon API + Neovim, P4 deferred/pushed docs + docs badge); P5 release verification pending |
| Phase 6 — Docker actions | Complete (6a manifest foundation, 6b runner, 6c web run experience); action log streaming and retention remain §16 deltas |
| Phase 7 — Storage engineering | In progress: 7a shipped (pack v2 + idx v2, delta reads, transparent `GitStore`, shared index cache); 7b repacker and 7c existence handshake pending |

## Current docs

| File | Purpose |
|---|---|
| `spec.md` | Canonical product/technical contract |
| `progress.md` | Current handoff and session summary |
| `demo.md` | Local demo stack: compose, seed accounts, guided tour |
| `phase-7-prep.md` | Phase 7 storage engineering: pack layer, repacker, existence handshake |
| `phase-6-prep.md` | Phase 6 Docker actions: scope, slices, decisions, risks (historical) |
| `ui-notes.md` | UI/tuning backlog — drop observations here between sessions |
| `phase-4-prep.md` | Phase 4 unions/proposals/review plan (historical) |
| `opencode.md` | Agent tooling: skills, formatter, gates, artifact conventions |
| `archive/` | Completed-phase briefs and historical progress log |

## Adding a phase brief

- Name it `phase-<n>-prep.md` for the next phase, or
  `phase-<n><letter>-prep.md` for a slice.
- State scope, verified state, dependencies, proposed slices, tests, acceptance,
  decisions, and risks.
- When the phase/slice ships, move the brief to `archive/` and update
  `progress.md` to point at the next brief.
