# Changelog

Notable changes to Cadence. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
