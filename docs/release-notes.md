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
  last-key warning. Password + TOTP or OAuth remains the recovery path, and
  credential changes require sudo mode.
- Cadence-owned `/sign-in` with the email/password form, configured OAuth
  buttons, and a first-class passkey CTA; `GET`/`POST /auth/passkeys/sign-in`
  creates a Cadence database session and uses one generic failure message.
- Hardening: both ceremony POSTs are per-IP rate-limited (`429` +
  `Retry-After`), `log: false`, CSRF-protected, and the production session
  cookie is now `secure` (dev/test/localhost stay usable).
- The demo stack enables WebAuthn on `localhost`; operator/end-user procedures
  are in `docs/passkeys.md`.

**Auth rebuild — local accounts, mandatory TOTP, database sessions**
- Email/password accounts created by the operator (`mix cadence.user` or
  `Cadence.Server.Release.create_user/2`); Argon2id hashing, a 12-character
  floor, uniform failure timing, and no public registration.
- TOTP is mandatory for local password accounts: QR enrollment on first login,
  encrypted secret at rest, replay prevention, ten one-use recovery codes, and
  sudo-gated regenerate/disable. OAuth and passkey accounts may opt in.
- Browser sessions are database rows (`user_sessions`) with hashed tokens,
  rotation on login, a 14-day remember-me cookie, 7-day reissue, logout
  revocation, LiveView disconnect, and a 20-minute sudo window.
- New `/sign-in`, `/sign-in/totp`, `/sign-in/totp/setup`, and `/account`
  surfaces; per-IP/per-email and per-user rate limits; `mix cadence.totp` for
  the demo/operator code.
- Visual pass: the DAG-fork mark, a real SVG favicon (`/favicon.ico` answers
  too), one centered auth card, and consistent account sections. No new font or
  site-wide redesign.
- The one-time API-key pages now use the normal site layout and auth-card
  styling, still with no JavaScript on the page.

**Self-hosting and editor install**
- `scripts/setup-prod.sh` generates `.env` (secret key base, database password,
  first admin password), prints the admin password once, and can start the
  reference stack.
- The reference compose stack derives `CAD_DATABASE_URL` from `CAD_DB_*`, adds
  an idempotent `bootstrap` service for the first account
  (`CAD_ADMIN_EMAIL` / `CAD_ADMIN_PASSWORD`), and optionally bundles Caddy under
  the `tls` profile (automatic Let's Encrypt or a local CA).
- The monorepo root now exposes `lua/` and `plugin/` entrypoints, so
  `vyynl/cadence` installs directly with lazy.nvim/LazyVim, Packer, vim-plug,
  or mini.deps. The plugin source stays in `cadence.nvim/`.
- `docker-compose.portainer.yml` is a paste-ready Portainer stack (no build
  context, no bind mounts, inline Caddy config). The new
  `.github/workflows/publish-image.yml` publishes
  `ghcr.io/vyynl/cadence-server` for it.

### Upgrade notes

- **New server dependencies:** `argon2_elixir ~> 4.0`, `nimble_totp ~> 1.0`, and
  `qr_code ~> 3.2` (with transitive `matrix_reloaded`, `pngex`,
  `xml_builder`, `ex_maybe`, `result`). `bcrypt_elixir` is no longer a direct
  dependency (AshAuthentication still pulls it transitively); run
  `mix deps.get`.
- **Server migrations:** `add_totp_fields` (users), `create_user_recovery_codes`,
  and `create_user_sessions`. All additive; run the normal one-shot `migrate`
  service. The daemon database is unchanged.
- **`CAD_DEMO_AUTH` is retired.** Password login is part of every build;
  operator-created accounts are the production path. Remove the variable and any
  `--build-arg` from deployment tooling. The demo image no longer takes it.
- **Existing browser sessions are invalidated once.** Ash `jti:sub` cookies are
  not database sessions, so every user signs in again after the upgrade.
- **First account:** the reference stack can now create it from
  `CAD_ADMIN_EMAIL` / `CAD_ADMIN_PASSWORD` through the one-shot `bootstrap`
  service; the manual `Release.create_user/3` / `mix cadence.user` path still
  works. The first password login forces TOTP enrollment. Password/TOTP resets
  are operator-only. Remove `CAD_ADMIN_PASSWORD` after the first sign-in.
- **New compose helpers:** `CAD_ADMIN_*`, `CAD_TLS_MODE`, `CAD_HTTP_BIND`, and
  `CAD_DB_*`. The reference stack derives `CAD_DATABASE_URL` from `CAD_DB_*`;
  set it explicitly only outside compose (or through an override for an
  external database). Run `scripts/setup-prod.sh` to generate a complete
  `.env`.
- **New env:** `CAD_AUTH_PASSWORD_MIN_LENGTH`, `CAD_AUTH_TOTP_REQUIRED`,
  `CAD_AUTH_TOTP_ISSUER`, `CAD_TOTP_KEY`, `CAD_AUTH_SUDO_MINUTES`,
  `CAD_AUTH_LOGIN_*`, `CAD_AUTH_TOTP_RATE_*`, `CAD_SESSION_TTL_DAYS`, and
  `CAD_SESSION_REISSUE_DAYS` (plus the demo-only `CAD_DEMO_HINTS`). Defaults are
  production-sane; see spec §12.6.
- **OAuth redirect:** a successful OAuth callback now returns to the stored
  local `return_to` or `/` (not always `/auth/tokens/new`). The account page
  links to token creation; update bookmarks/runbooks if they relied on the old
  redirect.
- **Passkeys:** sign-in creates a database session instead of an
  AshAuthentication session, and registration/rename/remove require sudo mode.
- **Demo:** seeded accounts use Argon2 + a fixed TOTP secret. Print the code
  with `docker compose exec server mix cadence.totp --email owner@demo.local`.
- **WebAuthn:** the `wax_` note below still applies; the session-cookie and
  demo-stack notes are superseded by the auth rebuild above.

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
- No passkey-only accounts, passkey recovery codes, or email magic links.
  Password + TOTP (or OAuth) is required for recovery; U2F-only keys are
  unsupported.
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

### Upgrade notes — Phase 9 / WebAuthn / CI

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
