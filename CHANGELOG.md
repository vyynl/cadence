# Changelog

Notable changes to Cadence. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The daemon image's `setup` now verifies the configuration while the operator
  is still at the prompt: it writes `daemon.env`, migrates, then calls the
  server and reports `server authenticated`, a rejected token (`401`), an
  untrusted certificate, or an unreachable URL (usually the missing `--network`).
  Backed by `Cadence.Daemon.Release.check_connection/0`, which
  `scripts/cadence-up.sh` uses too, so the mapping lives in one place.
- `CAD_SESSION_COOKIE_SECURE` (`public` by default, or `always` / `never`): the
  session and remember-me cookies are marked `Secure` only on the
  `CAD_PUBLIC_URL` host, and only when that origin is HTTPS. A deployment can now
  publish through a public domain and sign in over a LAN or Tailscale address
  without a TLS terminator in front of the private leg.
- `scripts/cadence-up.sh`: one command for the container flow. It runs `setup`
  when there is no `daemon.env`, starts or reuses the container (refusing when
  an existing one does not mount the project at its real path), retries
  registration across the boot window, reports the server connection separately,
  and prints the project URL as a clickable link. Idempotent; `--host` and
  `--require-connection` cover the release and strict cases.
- Daemon TLS trust for the server connection: `CAD_SYNC_CA_FILE` trusts a
  private CA bundle (a `CAD_TLS_MODE=internal` server, a LAN install, or an
  accepted inspecting proxy) and `CAD_SYNC_VERIFY_TLS=false` disables
  verification, for both the sync client and the notification socket. A CA path
  that is not a readable file stops the daemon at boot, and disabling
  verification logs a warning.
- The daemon image's `setup` now captures an optional LLM API key plus the
  provider, model, and base URL, and stores them in `daemon.env` with the server
  token. AI commit messages and doc automation can be enabled without putting
  the key in `docker run -e`; leaving it blank keeps them off.
- Project hub: `CAD_PROJECTS_ROOT` names a directory whose direct child
  directories become projects automatically. The hub is stored in `daemon.env`
  by `setup`, scanned once on boot and watched for new children, so a new
  folder is committed and synced without a register call. A child that is a Git
  repository imports its history with the existing importer; a plain directory
  gets one imported snapshot of its current tree. Hidden entries and paths that
  overlap an existing project are skipped; deleting or renaming a child does not
  delete its project.
- Imported history is now visibly flagged: nodes created by `mix cad.import` or
  the project hub carry the `imported` flag, and project pages and the portfolio
  show an imported badge. The flag is provenance, not a lifecycle state.

### Changed

- The daemon quickstart is remote-first: the copy-paste `docker run` commands
  target the server reached through `setup`, with no `--network` flag. The
  same-machine evaluation stack keeps the `cadence_default` /
  `cadence-prod_default` variant as an explicit note (`README.md`, `DAEMON.md`,
  `TROUBLESHOOTING.md`). Registering from a fresh clone still needs
  `mix deps.get && mix compile` first.
- `examples/minimal.yaml` exposes the four `CAD_LLM_*` variables like the full
  compose file, and the README/DEPLOY docs explain that the server needs the
  key for melds and the daemon for commit messages and docs.
- `DEPLOY.md` has a "Public domain with private access" section: the public
  origin builds the links, `CAD_SERVER_URL` may be a LAN or Tailscale address,
  and `CAD_SESSION_COOKIE_SECURE` decides where the cookie is hardened.
  `DAEMON.md` and `README.md` follow the same split, the daemon image's `setup`
  prompt now accepts a private address, and `TROUBLESHOOTING.md` covers a page
  whose panels stay on "Loading…".
- The daemon image's `setup` and start output is colour-coded (bold headings,
  dim hints, red errors) on a terminal, and plain when piped, when `NO_COLOR` is
  set, or when `TERM=dumb`.

### Fixed

- `scripts/cadence-up.sh` accepts a project mounted through a **parent** (the
  documented `-v "$HOME:$HOME"` flow) instead of demanding the project itself as
  a bind destination, and it takes the printed page link from `CAD_PUBLIC_URL`
  when that is set, because `CAD_SERVER_URL` is usually a compose service name
  (`http://cadence:4000`) that no browser resolves.
- Daemon helpers name the socket instead of crashing when it is missing or has
  no listener: `Release.register/4`, `Release.import/2`, and every `mix cad.*`
  task now report `cadence daemon unreachable at <path>: :econnrefused` (or
  `:enoent`) instead of a bare `MatchError`, so a `docker run -d` that has not
  finished binding its socket reads as "retry" rather than as a crash.
- The daemon quickstart no longer assumes a local server. The copy-paste
  `docker run` commands target the remote `CAD_SERVER_URL` entered in `setup`
  and carry no `--network` flag; the all-in-one evaluation stack's
  `cadence_default` / `cadence-prod_default` variant is now an explicit
  same-machine note. `setup`'s unreachable hint no longer claims a network flag
  is always missing.

### Security

- Updated `ash` to 3.38.1, `phoenix` to 1.8.17, `phoenix_live_view` to 1.2.15,
  `db_connection` to 2.10.3, and their resolved transitives for published
  advisories. The remaining `ex_aws` and `idna` advisories are accepted by exact
  advisory ID: `axiom_ai` (latest) pins `hackney` to 1.x, which blocks the
  patched `ex_aws`/`idna` releases. `ex_aws` is unreachable (Cadence never calls
  it) and `idna` only sees operator-configured hosts. The rationale and
  re-review date are in `.mix_audit.ignore` and `SECURITY.md`.

## [1.1.0] - 2026-11-18

Turnkey self-hosting, operator-created accounts with mandatory TOTP, passkeys,
Git import, a daemon terminal UI, and daemon-token management. Upgrade the
server image and the daemon together, and run the daemon migration once.

### Added

- Daemon token management: `/account` lists the signed-in account's personal
  access tokens (name, created, expiry) and revokes one on confirmation. A
  revoked key is rejected by `/sync/*` on its next request and by the
  notification socket on its next connection, so no SQL is needed to retire a
  leaked token.
- Git repository import: `mix cad.import` preserves original commit SHAs,
  parents (including merges), author timestamps, tags, and provenance, and
  pushes the imported DAG through the normal node API. Owner-only multi-parent
  push; paged public History.
- WebAuthn/passkeys: registration and sign-in, `/account/security` credential
  management, per-IP ceremony limits, and a `secure` production cookie.
- Local accounts: operator-created Argon2id passwords, mandatory TOTP with ten
  recovery codes, and database-backed browser sessions with rotation,
  remember-me, logout revocation, and a sudo window.
- Turnkey self-hosting: the compose stack generates its secrets, creates the
  first admin from a one-shot `bootstrap` service, and bundles Caddy under the
  `tls` profile. Root `lua/` and `plugin/` shims make the monorepo installable
  with lazy.nvim, Packer, vim-plug, and mini.deps.
- Docker Hub mirror: `publish-dockerhub.yml` republishes both images
  (`vyynl/cadence`, `vyynl/cadence-daemon`) with the GHCR tag set once
  `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` are configured. GHCR stays
  canonical, and the job skips with a notice while the secrets are absent.
- Terminal UI: `mix cad.tui` (and `Cadence.Daemon.TUI.main/1` from a release)
  drives the daemon over its Unix socket with DAG navigation, switch, spawn,
  union, proposals with OSC 52 URL copy, node/docs diffs, and docs sync. It is a
  pure socket client, so it works over SSH and needs no Neovim.

### Changed

- Minting a daemon token at `/auth/tokens/new` now requires the sudo window,
  like other credential changes: a minted token outlives browser sessions and
  password resets, so a stale session re-authenticates first.
- `CAD_DEMO_AUTH` and the compile-gated demo password strategy are retired.
  Password login is part of every build.
- A successful OAuth callback returns to the stored local `return_to` or `/`,
  no longer always to the token page.
- Existing browser sessions are invalidated once by the session rebuild, so
  every user signs in again after upgrading.

### Removed

- `bcrypt_elixir` is no longer a direct dependency; Argon2id is the password
  hash.

### Upgrade notes

- Pull the new server image and rebuild or pull the daemon release on each
  machine. The sync protocol is unchanged, so a 1.0.0 daemon keeps syncing to a
  1.1.0 server; the one ordering rule is that a TUI must not be newer than the
  daemon it connects to ([DAEMON.md](DAEMON.md)).
- Run the daemon migration once after upgrading
  (`bin/cadence_daemon eval "Cadence.Daemon.Release.migrate()"`, or
  `mix ecto.migrate -r Cadence.Daemon.Repo` from a checkout). It is safe to
  repeat.
- Re-run the demo stack with `--build`; the removed `CAD_DEMO_AUTH` variable is
  now ignored, so an old value is harmless but no longer needed.
- There is no destructive schema change in this release, but back up
  `CAD_STATE_DIR` and the Postgres volume before any upgrade.

### Known limitations

- Conflict-bearing melds and doc generation have not been smoke-tested live
  against a real `CAD_LLM_API_KEY`; conflict-free unions skip the model.
- Web review of generated docs is still deferred; the web UI shows a read-only
  docs badge.
- Action logs are captured after the container exits; there is no live stream.
- Each repack run adds a pack; there is no multi-pack index or consolidation.
- Docker Hub mirrors need `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`. GHCR is
  canonical, and CI publishes on `master` and `v*` tags.
- There is no WAF or bot protection in the app, and no `burrito` single-file
  daemon artifact. Image publishing remains operator-side for forks.

## [1.0.0] - 2026-11-11

The planned build order (spec Phases 1-8) is complete. This is the first
release whose contract is considered stable; remaining items are optional and
listed under Known limitations.

### Added

- **Daemon**: per-OS watcher backends with debounced auto-commits and a
  serialized queue per project; a Git object store with pack v2 reads and
  writes; optional AI commit messages and doc automation with rate limits and
  background retries; a Unix-socket API for the DAG, spawn/switch, unions, and
  docs; background sync with parent-first pushes and an existence handshake;
  `mix cad.*` tasks and a `cadence_daemon` release with ERTS bundled and Erlang
  distribution off.
- **Server**: Phoenix 1.8 / LiveView portfolio, full DAG, repository browser,
  and sanitized README rendering; proposals and incidents with integrity
  checks, quarantine, and verify-before-resolve; the meld pipeline
  (deterministic union, conflict-only model calls, strict parsing, materialized
  result, pending proposal); sandboxed Docker actions through an allowlisted
  socket proxy; pack-aware storage with a verified background repacker.
- **Neovim plugin**: `:CadOpen`, `:CadSpawn`, `:CadSwitch`, `:CadUnion`,
  `:CadProposals`, `:CadDocSync`, `:CadDocDiff`, the DAG picker, and hover
  diffs.
- **Demo stack**: one command gives a seeded, browsable dev-mode server.
- **Editor independence**: nodes come from the daemon's watcher, so any
  process writing inside a registered directory produces history.
- **CI**: one merge gate covering format, dev and prod compiles, tests, the 80%
  per-app coverage floor, Hex retirement and unused-lock checks, Sobelow,
  dependency CVEs, and a fail-closed advisory-database check.

### Upgrade notes

- Back up `CAD_STATE_DIR` before upgrading the daemon: the SQLite schema is not
  purely additive (`Project.actions_manifest` is dropped). Roll the release and
  the database back together.
- Run the daemon migration once after upgrading
  (`bin/cadence_daemon eval "Cadence.Daemon.Release.migrate()"`, or
  `mix ecto.migrate -r Cadence.Daemon.Repo` from a checkout). A boot on an
  unmigrated database is safe but syncs nothing.
- Rebuild the server image so it picks up the shared `config/runtime.exs` split;
  the daemon release no longer requires the server's prod variables.
- The daemon release is built per OS and architecture (`exqlite` ships a
  precompiled NIF). Linux needs `inotifywait` from `inotify-tools`, or set
  `CAD_WATCH_BACKEND=fs_poll`.

### Known limitations

- Conflict-bearing melds and doc generation have not been smoke-tested live
  against a real `CAD_LLM_API_KEY`; conflict-free unions skip the model.
- Web review of generated docs is deferred; the web UI shows a read-only docs
  badge.
- Action logs are captured after the container exits; there is no live stream.
- Each repack run adds a pack; there is no multi-pack index or consolidation.
- There is no WAF or bot protection in the app. Keep it behind normal edge
  protection if exposed publicly.
- Image publishing is operator-side; CI runs the merge gate but does not publish
  images. The actions volume must be size-limited by the operator.
- A `burrito` single-file daemon artifact is not implemented.

## See also

- [README.md](README.md): what Cadence is.
- [SECURITY.md](SECURITY.md): supported versions.
