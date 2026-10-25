# Cadence Docs

`docs/spec.md` is the canonical contract. If a design question is not answered
there, resolve it in the spec (or add it to §16) before implementing.

## Read order

1. `progress.md` — current phase, completed work, next step, blockers.
2. The phase brief named in **Next** (currently `phase-3b-prep.md`).
3. `spec.md` — the relevant sections for the task.

## Current status

| Phase | Status |
|---|---|
| Phase 1 — local daemon, commits, DAG picker, AI messages | Complete |
| Phase 2a — DAG structure, Neovim picker, diffs | Complete |
| Phase 2b — cloud sync, auth, preferences, notifications | Complete |
| Phase 3 — web UI & portfolio | **In progress (3d)** |
| Phase 4+ — unions, doc automation, actions, storage | Not started |

## Doc map

| File | Purpose |
|---|---|
| `spec.md` | Canonical product/technical contract |
| `progress.md` | Session handoff and implementation log |
| `phase-3-prep.md` | Cold-start brief for Phase 3 |
| `phase-3-roadmap.md` | Approved Phase 3 session plan and decisions |
| `phase-3b-prep.md` | 3b LiveView/DAG/repo-browser build brief |
| `phase-2b-cloud-sync.md` | Historical Phase 2b implementation plan |
| `phase-2b-3-prep.md` | Historical 2b-3 daemon sync brief |
| `phase-2b-4-prep.md` | Historical 2b-4 preferences/channel plan |
| `phase-2b-4b-prep.md` | Historical 2b-4b daemon-preference brief |

The separate `architecture.md`, `daemon.md`, `server.md`, and
`sync-protocol.md` files referenced in older notes were never created. Their
subject matter lives in `spec.md` §2, §5, §7, §10, and §12.

## Adding a phase brief

- Name it `phase-<n>-prep.md` for the next phase, or
  `phase-<n><letter>-prep.md` for a slice.
- State scope, current verified state, dependencies, proposed slices, tests,
  acceptance, and open questions.
- Mark it complete at the top when the phase/slice ships, and point to the
  next brief from `progress.md`.
- Keep historical briefs; they are useful context for why a design changed.
