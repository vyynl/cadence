# Cadence release notes

## Unreleased — 1.1.0 (on master)

Phase 9 (import a local Git repository) and the WebAuthn/passkey work are on
`master`; the version bump waits for the release cut, so the four `mix.exs`
projects stay at `1.0.0` until then. This section is the candidate text for
`1.1.0`.

### What ships

**Phase 9 — import a local Git repository**
- Shared read-only Git primitives and a daemon importer (`mix cad.import`) that
  preserves original SHAs, parents (including merges), author/timestamp
  provenance, and tags; the daemon pushes the imported DAG with the existing
  job API.
- Server owner-only multi-parent push and a sync body limit; a bounded DAG
  render window (`CAD_DAG_MAX_NODES`, intro skipped above
  `CAD_DAG_INTRO_MAX_NODES`) with deep node URLs that still open outside the
  window.
- Paged public History (`/p/:slug/history`, 50 per page) with imported
  provenance; the normal push scan still runs, so an imported secret opens a
  critical `secret_detected` incident and quarantines the snapshot.

**WebAuthn / passkeys (G1–G5)**
- `wax_` 0.7 behind a Cadence-owned relying-party layer: one-shot signed-session
  challenges, attestation `none`, required user verification, discoverable
  credentials, strict sign-count checking with a compare-and-swap, and
  user-scoped credential storage.
- `/account/security`: list keys with label/transport/added/last-used, rename,
  remove-after-confirmation, per-user cap (`CAD_WEBAUTHN_MAX_CREDENTIALS`), and
  last-key warning. OAuth remains the recovery path.
- Cadence-owned `/sign-in` with the existing OAuth/demo components and a
  first-class passkey CTA; `GET`/`POST /auth/passkeys/sign-in` renews the
  session and uses one generic failure message.
- Hardening: both ceremony POSTs are per-IP rate-limited (`429` +
  `Retry-After`), `log: false`, CSRF-protected, and the production session
  cookie is now `secure` (dev/test/localhost stay usable).
- The demo stack enables WebAuthn on `localhost`; operator/end-user procedures
  are in `docs/passkeys.md`.

### Upgrade notes

- **New server dependency:** `wax_ ~> 0.7` (Apache-2.0), with transitive
  `cbor`, `x509`, and `asn1_compiler`. Run `mix deps.get`; no daemon or shared
  dependency changed.
- **Server migration:** `20261112032926_add_webauthn_credentials.exs` creates
  `webauthn_credentials`. It is additive; run the normal one-shot
  `migrate` service (or `mix ecto.migrate -r Cadence.Server.Repo`). The daemon
  database is unchanged.
- **New opt-in env:** `CAD_WEBAUTHN_ENABLED=false` by default. To enable,
  set `CAD_WEBAUTHN_RP_ID` (permanent hostname) and `CAD_WEBAUTHN_ORIGIN`
  (exact public `https://` origin); see `docs/passkeys.md`. A bad value fails
  the boot when the feature is enabled.
- **Session cookie:** a `MIX_ENV=prod` build now sets `secure` on
  `_cadence_key` (still `http_only`, `SameSite=Lax`). Production must be served
  over HTTPS; a prod release over plain HTTP will not keep sessions. Dev/test
  and the demo are unchanged.
- **Demo stack:** `docker compose up --build` now sets the three WebAuthn
  variables for `localhost`; nothing is required for existing demo users.

### Known limitations

- The physical browser/OS/YubiKey matrix (USB/NFC, PIN/fingerprint, platform and
  cross-device passkeys, wrong-PIN retries, key-full, proxy mismatch) is a
  release-checklist item and has not been run against real hardware in CI.
  Conditional/autofill UI and a passkey step-up before minting a daemon PAT are
  deferred.
- Attestation is `none`: any authenticator, including a virtual one, is
  accepted. Possession plus user verification is the assurance model; there is
  no MDS/AAGUID allowlist.
- No passkey-only accounts, recovery codes, or email magic links. OAuth (or the
  demo password) is required for recovery; U2F-only keys are unsupported.
- The ceremony rate limiter is in-memory and per node/IP; the challenge GETs
  are not limited and there is no separate per-credential bucket.
- The 1.0.0 notes' accepted `hackney` and `assent` advisories still apply; they
  remain ignored by exact advisory ID.

## 1.0.0 — 2026-11-11

The planned build order (spec §13, Phases 1–8) is complete. Cadence is a
local-first, self-hosted source control system built on a DAG of snapshots.
This is the first release with the documented contract considered stable; the
items still open in spec §16 are optional and listed under **Known
limitations**.

### What ships

**Local daemon (`cadence_daemon`)**
- File watcher with per-OS backends (`fs_inotify` on Linux, `fs_poll`
  elsewhere) and debounced auto-commits; one serialized commit queue per
  project.
- A project directory that disappears is retried instead of crash-looping; a
  broken project can no longer take the project registry (and every other
  project) down with it.
- Git object store (`Cadence.Shared.GitStore`) with pack v2 + idx v2 reads and
  writes, delta chains, and a verified repacker on the server side.
- AI commit messages and doc automation through the configured `CAD_LLM_*`
  client, with Hammer rate limits and background retries. Both are optional.
- Unix-socket API: register projects, list nodes/graph/diff, spawn/switch,
  submit unions, list the local union journal, queue docs sync, and read docs
  diffs.
- Background sync: provisioning, parent-first pushes, existence handshake,
  pulls, LWW preferences, and an optional notification socket.
- `mix cad.*` tasks and the `cadence_daemon` release (ERTS bundled, no Erlang
  distribution; stop with SIGTERM / systemd).

**Server (`cadence_server`)**
- Phoenix 1.8 / LiveView 1.2 public portfolio, full DAG, repository browser,
  MDEx README rendering (sanitized), and member views.
- AshAuthentication: GitHub/Google OAuth in production, a compile-gated demo
  password strategy, and personal access tokens for daemons.
- Proposals and incidents: public read-only proposal links, a member review
  hub, approve/reject with integrity checks, quarantine for secrets and
  sensitive paths, and an incident panel with verify-before-resolve.
- Meld/union pipeline: deterministic union, conflict-only agent calls,
  strict parsing, Elixir/binary guards, result materialization, and a pending
  proposal (never an auto-promoted node).
- Docker actions: a strictly parsed `actions/manifest.json`, a durable run
  queue (per-project concurrency and depth caps), sandboxed containers through
  an allowlisted socket proxy, post-exit logs, artifact downloads, retention,
  and paged run history.
- Storage: pack-aware reads, background repacking with a timeout and cooldown,
  and the sync existence handshake.
- Release artifact: `docker/Dockerfile` + `docker-compose.prod.yml` with a
  one-shot migration service; `mix release cadence`.

**Neovim plugin (`cadence.nvim`)**
- `:CadOpen`, `:CadSpawn`, `:CadSwitch`, `:CadUnion`, `:CadProposals`,
  `:CadDocSync`, `:CadDocDiff`, the DAG picker, and hover diffs.

**Demo stack**
- `docker compose up --build` gives a seeded, browsable server on
  <http://localhost:4000> (`docs/demo.md`).

**Editor independence**
- Neovim is optional. Nodes are created by the daemon's watcher from
  working-tree changes, and the sync worker pushes them. Any process writing
  inside a registered project directory — an IDE, another editor, a script, an
  AI coding tool — produces nodes. The plugin only adds the DAG picker and
  convenience commands; its daemon endpoints are plain HTTP over `daemon.sock`
  (`docs/daemon-setup.md`).

**Continuous integration**
- One merge-gate workflow (`.github/workflows/ci.yml`) runs formatting, dev and
  prod compiles, tests, the per-app 80% coverage floor, Hex retirement and
  unused-lock checks, Sobelow, dependency CVE scanning, and a fail-closed
  advisory-database check.

### Upgrade notes

- **Back up `CAD_STATE_DIR` before upgrading the daemon.** This release's
  SQLite schema is not purely additive: `Project.actions_manifest` is dropped.
  Roll the release and the database back together; a rollback needs a source
  checkout.
- Run the daemon migration once after upgrading:
  `~/.local/share/cadence/bin/cadence_daemon eval "Cadence.Daemon.Release.migrate()"`
  (source checkout: `mix ecto.migrate -r Cadence.Daemon.Repo`). A boot on an
  unmigrated database is safe but syncs nothing.
- Rebuild the server image so it picks up the shared `config/runtime.exs`
  split (the daemon release no longer requires the server's prod variables).
  Older images still work and still require them.
- `ash_postgres` moved to 2.15.2 (the 2.14 series is retired by Hex).
- The daemon release is built per OS/arch (`exqlite` ships a precompiled NIF).
  Linux needs `inotifywait` (`inotify-tools`) or `CAD_WATCH_BACKEND=fs_poll`.

### Known limitations

- Conflict-bearing melds and doc generation have not been smoke-tested live
  with a real `CAD_LLM_API_KEY`; conflict-free unions skip the model.
- Web docs review (approving/rejecting generated docs) is deferred; the web UI
  shows a read-only docs badge.
- Action logs are captured after the container exits; there is no live stream.
- Pack consolidation / a multi-pack index is not implemented; each repack run
  adds a pack.
- Keep the server behind normal edge protection if exposed publicly. `/sync/*`
  is rate-limited per authenticated user, meld calls have their own per-project
  limiter, and public proposal results are cached, but there is no WAF or bot
  protection in the app.
- Image publishing is operator-side; the CI workflow runs the merge gate but
  does not publish images. `Project.docker_image` has no admin writer; action
  containers run in the host user namespace with no `/out` quota, so the
  actions volume must be size-limited.
- Multi-node server fan-out, the public-preview auth decision, and the cloud
  backup strategy remain open.
- A `burrito` single-file daemon artifact is not implemented (it would need a
  spec §11 dependency row).
