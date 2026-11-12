# Cadence Docs

`docs/spec.md` is the canonical contract. If a design question is not answered
there, resolve it in the spec (or add it to §16) before implementing.

## Where to start

| Document | Purpose |
|---|---|
| [`spec.md`](spec.md) | Canonical product and technical contract |
| [`release-notes.md`](release-notes.md) | Release history, upgrade notes, and known limitations |
| [`daemon-setup.md`](daemon-setup.md) | Local daemon: release or source install, token, env file, migration, boot, registration, upgrades |
| [`deploy.md`](deploy.md) | Production server: release image, compose stack, migrations, volumes, actions |
| [`demo.md`](demo.md) | One-command demo stack, seeded accounts, and the guided tour |
| [`webauthn-plan.md`](webauthn-plan.md) | Approved WebAuthn/passkey (FIDO2) design: YubiKey, recovery, schema, phases |
| [`ui-notes.md`](ui-notes.md) | UI/tuning backlog — visual, layout, and copy observations |
| [`images/`](images/) | Screenshots referenced by the docs |

Project entry points:

- [`../README.md`](../README.md) — overview, quickstart, and the CI gate
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — setup, tests, hard rules, and pull requests
- [`../SECURITY.md`](../SECURITY.md) — supported versions and private vulnerability reporting

## Project status

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
| Phase 9 — Import a local Git repository | Complete (9a shared primitives, 9b daemon importer/API/CLI, 9c multi-parent push + body limit, 9d capped DAG + paged History + provenance, 9e docs/spec/live smoke) |
| WebAuthn / passkeys | Design approved; G1 data/config/Wax spike in progress |

Current release: **1.0.0** (2026-11-11) — the planned build order (Phases 1–8)
is complete; remaining work is optional and recorded in spec §16 and
`release-notes.md`.

## Documentation conventions

- Anchor links use spec section numbers (`§7.3`) so a change can be traced from
  code and tests back to the contract.
- User-facing behavior changes update `spec.md` and `release-notes.md` in the
  same change.
- Configuration belongs in spec §12.6 and `.env.example`; do not hide defaults
  in prose only.
- Screenshots live in `images/` and are referenced from the doc that uses them.
