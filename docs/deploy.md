# Production deployment

The server ships as a self-contained Elixir release inside the image built from
`docker/Dockerfile` ([spec §12.3](spec.md#123-server),
[§12.8](spec.md#128-build-release)). `docker-compose.prod.yml` is the
reference stack: the app, PostgreSQL, a Docker socket proxy, and a one-shot
migration service.

This is **not** the demo stack. The demo (`docker-compose.yml`,
`docker/Dockerfile.demo`) builds with `MIX_ENV=dev`, seeds demo accounts, and
exists for browsing the UI. See [`demo.md`](demo.md).

## At a glance

- **Server:** a `MIX_ENV=prod` release in a non-root Debian container.
- **Database:** PostgreSQL 16, migrated by a one-shot `migrate` service before
  the app starts.
- **TLS:** terminated by your reverse proxy; Cadence serves plain HTTP on
  `CAD_HTTP_PORT` (default 4000).
- **State:** named volumes for PostgreSQL, Git object stores, action
  artifacts, and staged action snapshots.
- **Actions:** optional; require Docker 26+ and the socket proxy.

## Prerequisites

- Docker Engine 26 or newer (the action runner uses the `volume-subpath` mount
  option, Docker API `v1.45`) and Docker Compose v2.17+.
- A TLS-terminating reverse proxy (Caddy, nginx, or TrueNAS built-in).
- PostgreSQL 16 (the reference stack runs it in a container).
- For Docker actions: a filesystem with a size limit for
  `CAD_ACTIONS_VOLUME_PATH` ([spec §8.4](spec.md#84-security)) and the
  socket **proxy** — never the raw socket.

## Secrets and configuration

Production boots raise if `CAD_SECRET_KEY_BASE`, `CAD_DATABASE_URL`, or
`CAD_PUBLIC_URL` is missing. Generate the secret and keep the env file private:

```bash
cp .env.example .env
chmod 600 .env
openssl rand -base64 48   # CAD_SECRET_KEY_BASE
openssl rand -base64 48   # CAD_LIVE_VIEW_SALT (optional)
```

Set at least:

| Variable | Notes |
|---|---|
| `CAD_PHX_HOST` | Hostname the app is served from (`cadence.example.com`). |
| `CAD_PUBLIC_URL` | Absolute public URL (`https://cadence.example.com`), used for OAuth callbacks and proposal links. |
| `CAD_SECRET_KEY_BASE` | 64+ random bytes; rotating it invalidates sessions. |
| `CAD_DATABASE_URL` | `ecto://USER:PASS@postgres:5432/DB` for the compose stack. |
| `CAD_DB_USER` / `CAD_DB_PASS` / `CAD_DB_NAME` | Read by the compose PostgreSQL service; keep them consistent with `CAD_DATABASE_URL`. |
| `CAD_OAUTH_GITHUB_*` / `CAD_OAUTH_GOOGLE_*` | Client id and secret for human sign-in. Redirect URI: `https://<CAD_PHX_HOST>/auth/user/<provider>/callback`. |
| `CAD_AUTH_*` / `CAD_TOTP_KEY` / `CAD_SESSION_*` | Local password/TOTP policy, TOTP secret encryption, and session lifetimes. Defaults are production-sane; see [spec §12.6](spec.md#126-environment-variable-contract). |
| `CAD_WEBAUTHN_*` | Optional passkey/security-key sign-in (default off). See [Passkeys](#passkeys). |
| `CAD_LLM_API_KEY` | Optional. Required only for melds or docs that need the model; conflict-free melds skip it. |

`CAD_LIVE_VIEW_SALT` and `CAD_TOKEN_SIGNING_SECRET` fall back to
`CAD_SECRET_KEY_BASE`. Local password login is always part of the build;
accounts are created by the operator (there is no public registration), and TOTP
is mandatory for local accounts by default. OAuth and passkeys are secondary.

## First account

Before the first sign-in, create the operator account from the running
container (or run the same `eval` against a one-shot container):

```bash
docker compose -f docker-compose.prod.yml exec cadence \
  /app/bin/cadence eval 'Cadence.Server.Release.create_user("you@example.com", "Your Name", "a long password")'
```

Sign in at `/sign-in` with that password; the first login forces TOTP
enrollment. The recovery codes are shown once. To reset a password or TOTP
later, use `Release.reset_password/2` or `Release.reset_totp/1` the same way
(`mix cadence.user --reset-password|--reset-totp` is the source-checkout
equivalent). There is no password-reset email.

`CAD_TOTP_KEY` is optional (32 raw bytes, base64, or a passphrase); when absent,
the encryption key is derived from `CAD_SECRET_KEY_BASE`. Rotating either makes
stored TOTP secrets undecryptable — reset them per account.

## Quick start

```bash
docker compose -f docker-compose.prod.yml up -d --build
```

Compose builds `cadence-server:prod`, runs the `migrate` service
(`/app/bin/cadence eval "Cadence.Server.Release.migrate()"`), and starts
`cadence` only after the migration exits 0. The same sequence is in
[spec §12.7](spec.md#127-first-boot-sequence-server).

The compose project is `cadence-prod`, distinct from the demo project
(`cadence`), so `down` / `down -v` on one stack cannot touch the other. The
pinned `cadence_actions` volume is shared with the host Docker daemon by design.

## Verify

```bash
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs migrate
curl -fsS https://cadence.example.com/health   # {"status":"ok"}
```

Then sign in at `/sign-in` with the operator password and the current TOTP code,
open `/account` to manage credentials, `/account/security` if passkeys are
enabled, and register a project from the daemon
([`daemon-setup.md`](daemon-setup.md)).
The daemon's `CAD_SERVER_URL` must be reachable **by the daemon**; public
proposal links come from the server's `CAD_PUBLIC_URL`, so an internal daemon
URL is fine.

The compose app listens on 4000 inside the container and publishes
`CAD_HTTP_PORT` (default 4000). Point the reverse proxy at that port. Running the
image outside compose is supported: set `CAD_HTTP_PORT` and expose the same port
(the image healthcheck follows it).

## Passkeys

Passkeys are an additional browser sign-in method for existing accounts and are
off by default. They do not create accounts; the account password + TOTP (or
OAuth) remains the recovery path. The operator and end-user runbook is
[`passkeys.md`](passkeys.md); the design record is
[`webauthn-plan.md`](webauthn-plan.md).

The complete contract is
[spec §12.6](spec.md#126-environment-variable-contract); the nine
`CAD_WEBAUTHN_*` keys and their defaults are listed in
[`passkeys.md`](passkeys.md#configuration). A production deployment normally
sets only these three:

| Variable | Default | Notes |
|---|---|---|
| `CAD_WEBAUTHN_ENABLED` | `false` | Enable registration, the account security page, and passkey sign-in. |
| `CAD_WEBAUTHN_RP_ID` | `localhost` | Relying Party ID: a hostname only, no scheme, port, or path. **Permanent** — changing it invalidates every credential. |
| `CAD_WEBAUTHN_ORIGIN` | `CAD_PUBLIC_URL` in dev; required in prod | Exact public origin (`https://host[:port]`), with no trailing slash. Required behind a TLS-terminating proxy. |

```bash
CAD_WEBAUTHN_ENABLED=true
CAD_WEBAUTHN_RP_ID=cadence.example.com
CAD_WEBAUTHN_ORIGIN=https://cadence.example.com
CAD_WEBAUTHN_RP_NAME=Cadence
```

A bad RP ID or origin fails the boot when the feature is enabled. Pick the
permanent hostname before the first key is registered; there is no migration.

## Migrations and upgrades

```bash
git pull
docker compose -f docker-compose.prod.yml up -d --build
```

`migrate` is a one-shot service that runs on every `up`; `Ecto.Migrator` skips
already-applied versions, so a second run is a no-op. The app is not started
until the migration succeeds.

Manual runs:

```bash
# The compose service (uses the image and the env from compose)
docker compose -f docker-compose.prod.yml run --rm migrate

# Inside a running container
docker compose -f docker-compose.prod.yml exec cadence \
  /app/bin/cadence eval "Cadence.Server.Release.migrate()"
```

Rollback is intentionally not wrapped: it is destructive and operator-specific.
Run `Ecto.Migrator.run`/`:down` through `bin/cadence eval` only with a tested
backup. Do not point two independently-started stacks at one database.

## Volumes and ownership

| Volume | Mount | Contents |
|---|---|---|
| `cadence_data` | `/data` | Git object stores (loose objects and packs). |
| `cadence_artifacts` | `/data/artifacts` | Action logs and collected artifacts. |
| `cadence_actions` | `/data/actions` | Staged snapshots and `/out` subpaths for action containers (`CAD_ACTIONS_VOLUME`). |
| `postgres_data` | `/var/lib/postgresql/data` | PostgreSQL. |

The logical names above are what the compose file declares. The pinned action
volume keeps `cadence_actions` exactly; the others are prefixed with the compose
project name, so on disk they are `cadence-prod_cadence_data`,
`cadence-prod_cadence_artifacts`, and `cadence-prod_postgres_data`
(`docker volume ls`).

The container runs as the image's non-root `cadence` user. Named volumes inherit
the image's ownership on first creation. Bind-mounted host directories must be
writable by the same uid/gid:

```bash
docker run --rm --entrypoint id cadence-server:prod
# uid=... gid=... groups=...
sudo chown -R <uid>:<gid> /srv/cadence/data /srv/cadence/artifacts
```

`cadence_actions` is **pinned by name** in the compose file on purpose: the host
Docker daemon mounts that exact volume into action containers by subpath
(`CAD_ACTIONS_VOLUME`). Both the volume name and the app setting read
`CAD_ACTIONS_VOLUME` (default `cadence_actions`), so overriding it keeps them in
sync; compose prefixing the volume would break actions.

## Docker actions

- `CAD_ACTIONS_ENABLED=false` disables the runner, run pages, and downloads. The
  reference stack still starts the proxy; you may remove it if actions are off.
- The socket proxy is **root-equivalent** on the host
  ([spec §8.4](spec.md#84-security)). The app reaches it at
  `http://docker-proxy:2375`; action containers run with no network by default
  and cannot reach it.
- Point `CAD_ACTIONS_VOLUME_PATH` at a filesystem with a size limit: an action
  can fill it during its timeout; post-exit collection caps only the copy
  ([spec §8.3](spec.md#83-isolation)).
- Project `Dockerfile` `FROM` pulls run on the host Docker daemon, so treat them
  as able to reach any registry the daemon can reach.

## Building and publishing the image

The compose file builds locally. To publish a versioned image:

```bash
docker build -f docker/Dockerfile -t ghcr.io/you/cadence-server:1.0.0 .
docker push ghcr.io/you/cadence-server:1.0.0
```

Then set `CAD_SERVER_IMAGE=ghcr.io/you/cadence-server:1.0.0` in `.env` and run
`docker compose -f docker-compose.prod.yml pull` (the `cadence` service still
declares a local `build:`; `pull` uses the tagged image).

CI ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) runs the merge
gate but does not build or publish images. Registry publishing and version
pinning are operator-managed; the workflow's first remote run is operator-side.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Boot raises on a missing env var | `runtime.exs` requires `CAD_SECRET_KEY_BASE`, `CAD_DATABASE_URL`, `CAD_PUBLIC_URL` in `MIX_ENV=prod`. Set them in `.env`. |
| `CAD_DEMO_AUTH must never be set…` | This flag no longer exists. Remove it from `.env`; password login is part of every build now. |
| `migrate` exits non-zero | Check `docker compose … logs migrate`; usually the database URL, user, password, or a missing extension. The app will not start until it passes. |
| Container is `unhealthy` | `docker compose … logs cadence`; the healthcheck calls `/health` on port 4000. A config raise happens before the endpoint binds. |
| Permission denied under `/data` | The volume or bind mount is not writable by the `cadence` uid. See [Volumes and ownership](#volumes-and-ownership). |
| Action run fails `docker_unavailable` | Proxy not reachable or Docker older than 26. Check `CAD_DOCKER_SOCKET` and the proxy logs. |
| Cannot sign in | Use the operator-created password, then the current TOTP code. A local account that has not enrolled is sent to `/sign-in/totp/setup`; an expired pending hand-off returns to `/sign-in`. |
| Lost authenticator or TOTP key rotated | `bin/cadence eval 'Cadence.Server.Release.reset_totp("you@example.com")'`, then sign in and re-enroll. |
| Passkey prompt never appears | Origin is not a secure context, or `CAD_WEBAUTHN_ORIGIN`/`RP_ID` does not match. See [`passkeys.md`](passkeys.md#troubleshooting). |

## Security checklist

- TLS at the proxy; `CAD_PUBLIC_URL` is `https://`.
- `.env` is `chmod 600`; never commit it.
- Docker socket access goes through the allowlisted proxy only; never bind the
  raw socket into the app container on a reachable host.
- Review `CAD_ACTIONS_*` limits before enabling actions; keep the artifact
  volume size-limited.
- Back up `postgres_data` and `cadence_data` together (metadata and object
  store). There is no built-in backup task yet
  ([spec §16](spec.md#16-open-decisions)).
- If passkeys are enabled, keep a working password+TOTP or OAuth method for
  every human account and treat `CAD_WEBAUTHN_RP_ID` as permanent.
- TOTP is mandatory for local accounts by default; keep `CAD_TOTP_KEY` stable
  (or accept a per-account reset after rotating it).

## Related docs

- [Daemon setup](daemon-setup.md) — the local half and project registration.
- [Demo stack](demo.md) — a browsable local server.
- [Import a Git repository](import.md) — history adoption after deployment.
- [Security keys and passkeys](passkeys.md) — enable and operate WebAuthn.
- [Spec §12](spec.md#12-deployment-model) — deployment contract.
- [Security policy](../SECURITY.md) — private vulnerability reporting.
