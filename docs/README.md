# Cadence documentation

`docs/spec.md` is the canonical contract. If a design question is not answered
there, resolve it in the spec (or add it to [§16 Open Decisions](spec.md#16-open-decisions))
before implementing.

## Start here

- [Demo stack](demo.md) — run a seeded server with one command and take the
  guided tour.
- [Import a Git repository](import.md) — adopt an existing local repository and
  publish its history.
- [Daemon setup](daemon-setup.md) — install the local daemon, mint a token,
  register a project, and keep it running.
- [Security keys and passkeys](passkeys.md) — enable WebAuthn, enroll a YubiKey
  or phone passkey, and recover access.
- [Accounts, TOTP, and sessions](auth.md) — operator-created accounts, first
  login, recovery codes, remember-me, sudo mode, and resets.

## Operate

- [Production deployment](deploy.md) — build the server image, run the compose
  stack, migrate, and manage volumes.
- [Docker actions](deploy.md#docker-actions) — socket proxy, isolation limits,
  and the volume prerequisite.
- [Troubleshooting](deploy.md#troubleshooting) — server boot, migration, and
  action failures. Daemon symptoms are in
  [daemon setup](daemon-setup.md#troubleshooting).

## Reference

- [Specification](spec.md) — canonical product, protocol, and deployment
  contract.
- [Release notes](release-notes.md) — what ships, upgrade notes, and known
  limitations. Current release: **1.0.0**; 1.1.0 is unreleased on `master`.
- [WebAuthn design note](webauthn-plan.md) — the approved passkey design and the
  remaining hardware matrix.
- [UI backlog](ui-notes.md) — internal visual, layout, and copy follow-ups.

## Contribute

- [Contributing](../CONTRIBUTING.md) — setup, tests, the merge gate, and the
  hard rules.
- [Security policy](../SECURITY.md) — supported versions and private reporting.
- [MIT License](../LICENSE) — copyright and terms.

## Project status

Cadence 1.0.0 is released (2026-11-11), completing the planned build order
(Phases 1–8). Phase 9 (Git import), WebAuthn/passkeys, and the local-account/
TOTP/session auth rebuild are on `master` and recorded as unreleased in the
[release notes](release-notes.md). Remaining work is optional and tracked in
[spec §16](spec.md#16-open-decisions).

## Documentation conventions

- Anchor links use spec section numbers (`§7.3`) so code and tests can be traced
  back to the contract.
- A user-facing behavior change updates `spec.md` and `release-notes.md` in the
  same change.
- Configuration belongs in [spec §12.6](spec.md#126-environment-variable-contract)
  (authoritative) and `.env.example` (the deployable subset); do not document
  defaults only in prose.
- Terminology: **node** is the graph object, **snapshot** is its tree, and
  **commit** is the Git object. Write **Git** in prose and `git` only in
  commands.
- Screenshots live in `docs/images/` and are referenced from the document that
  uses them.
