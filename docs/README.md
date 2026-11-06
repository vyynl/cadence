# Cadence Docs

`docs/spec.md` is the canonical contract. If a design question is not answered
there, resolve it in the spec (or add it to §16) before implementing.

## Read order

1. `progress.md` — current phase, summary, next step, blockers.
2. `phase-4-prep.md` — current phase brief.
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
| Phase 5 — doc automation | In progress (5a shared primitives, 5b daemon worker, 5c daemon API + Neovim, and P4-T1 reconnect docs retry complete; P4-T2 pushed-node fallback + P4-T3 badge + closeout next) |

## Current docs

| File | Purpose |
|---|---|
| `spec.md` | Canonical product/technical contract |
| `progress.md` | Current handoff and session summary |
| `demo.md` | Local demo stack: compose, seed accounts, guided tour |
| `ui-notes.md` | UI/tuning backlog — drop observations here between sessions |
| `phase-4-prep.md` | Phase 4 unions/proposals/review plan |
| `opencode.md` | Agent tooling: skills, formatter, gates, artifact conventions |
| `archive/` | Completed-phase briefs and historical progress log |

## Adding a phase brief

- Name it `phase-<n>-prep.md` for the next phase, or
  `phase-<n><letter>-prep.md` for a slice.
- State scope, verified state, dependencies, proposed slices, tests, acceptance,
  decisions, and risks.
- When the phase/slice ships, move the brief to `archive/` and update
  `progress.md` to point at the next brief.
