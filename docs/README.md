# Cadence Docs

`docs/spec.md` is the canonical contract. If a design question is not answered
there, resolve it in the spec (or add it to §16) before implementing.

## Read order

1. `progress.md` — current phase, summary, next step, blockers.
2. `deploy.md` for production/operator work, or `archive/` for historical
   context.
3. `spec.md` — the relevant sections for the task.

Completed-phase briefs and the full Phase 1–3 log live in `archive/`; they are
history, not current instructions. The 1.0.0 release summary and known
limitations are in `release-notes.md`.

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
| Phase 6 — Docker actions | Complete (6a manifest foundation, 6b runner, 6c web run experience, post-close run queue, retention and run/artifact paging); action log streaming remains a §16 delta |
| Phase 7 — Storage engineering | Complete (7a pack layer, 7b repacker, 7c existence handshake, 7d multi-pack/index/delta-depth/repack verification + demo-stack smoke); pack consolidation remains a §16 delta |
| Phase 8 — Release engineering | Complete (8a production server image, umbrella release, `Cadence.Server.Release.migrate/0`, prod compose, deploy docs; 8b `cadence_daemon` release with `Cadence.Daemon.Release.migrate/0`, release registration, systemd/install/upgrade docs) |

Current release: **1.0.0** (2026-11-11) — the planned build order (Phases 1–8)
is complete; remaining work is optional and recorded in spec §16 and
`release-notes.md`.

## Current docs

| File | Purpose |
|---|---|
| `spec.md` | Canonical product/technical contract |
| `progress.md` | Current handoff and session summary |
| `release-notes.md` | Release history, upgrade notes, and known limitations |
| `audit-2026-11-11.md` | Final five-track health audit (scores, findings, smoke result) |
| `audit-100-plan.md` | Gap-closing plan from the 87/89 baseline to a 100 rubric score |
| `daemon-setup.md` | Local daemon setup: release or source install, token, env file, migration, boot, registration, upgrades |
| `deploy.md` | Production server: release image, compose stack, migrations, volumes, actions |
| `demo.md` | Local demo stack: compose, seed accounts, guided tour |
| `ui-notes.md` | UI/tuning backlog — drop observations here between sessions |
| `opencode.md` | Agent tooling: skills, formatter, gates, artifact conventions |
| `phase-9-prep.md` | Phase 9 import brief: Git history → Cadence DAG (proposed) |
| `archive/` | Completed-phase briefs and historical progress log |

## Adding a phase brief

- Name it `phase-<n>-prep.md` for the next phase, or
  `phase-<n><letter>-prep.md` for a slice.
- State scope, verified state, dependencies, proposed slices, tests, acceptance,
  decisions, and risks.
- When the phase/slice ships, move the brief to `archive/` and update
  `progress.md` to point at the next brief.
