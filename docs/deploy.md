# Production deployment

The server ships as a self-contained Elixir release inside the image built from
`docker/Dockerfile` ([spec §12.3](spec.md#123-server),
[§12.8](spec.md#128-build-release)). `docker-compose.prod.yml` is the
reference stack: the app, PostgreSQL, a Docker socket proxy, one-shot migration
and first-account services, and an optional bundled Caddy.

The fastest path is:

```bash
./scripts/setup-prod.sh cadence.example.com you@example.com --up
```

The script generates `.env` (secret key base, database password, first admin
password), prints the admin password once, and starts the stack. The rest of
this guide documents what it writes and the manual equivalent.

This is **not** the demo stack. The demo (`docker-compose.yml`,
`docker/Dockerfile.demo`) builds with `MIX_ENV=dev`, seeds demo accounts, and
exists for browsing the UI. See [`demo.md`](demo.md).

## At a glance

- **Server:** a `MIX_ENV=prod` release in a non-root Debian container.
- **Database:** PostgreSQL 16, migrated by a one-shot `migrate` service before
  the app starts.
- **First account:** an idempotent `bootstrap` service creates it from
  `CAD_ADMIN_*` on first boot (or does nothing when the password is unset).
- **TLS:** bundled Caddy under the `tls` profile (automatic or internal CA), or
  your own reverse proxy. Cadence serves plain HTTP on `CAD_HTTP_PORT`
  (default 4000), bound to loopback by default.
- **State:** named volumes for PostgreSQL, Git object stores, action
  artifacts, staged action snapshots, and Caddy data.
- **Actions:** optional; require Docker 26+ and the socket proxy.

## Prerequisites

- Docker Engine 26 or newer (the action runner uses the `volume-subpath` mount
  option, Docker API `v1.45`) and Docker Compose v2.17+.
- A DNS name that resolves to the server. For `--tls auto`, ports 80 and 443
  must be reachable so Caddy can obtain a certificate.
- PostgreSQL 16 (the reference stack runs it in a container).
- A TLS-terminating reverse proxy **only** when using `--tls external` or
  removing the bundled Caddy.
- For Docker actions: a filesystem with a size limit for
  `CAD_ACTIONS_VOLUME_PATH` ([spec §8.4](spec.md#84-security)) and the
  socket **proxy** — never the raw socket.

## Secrets and configuration

`scripts/setup-prod.sh` writes a complete `.env` with generated values and
`chmod 600`. For the manual path:

```bash
cp .env.example .env
chmod 600 .env
openssl rand -hex 48      # CAD_SECRET_KEY_BASE
openssl rand -hex 24      # CAD_DB_PASS
```

Set at least:

| Variable | Notes |
|---|---|
| `CAD_PHX_HOST` | Hostname the app is served from (`cadence.example.com`). |
| `CAD_PUBLIC_URL` | Absolute public URL (`https://cadence.example.com`), used for OAuth callbacks and proposal links. |
| `CAD_SECRET_KEY_BASE` | 64+ random bytes; rotating it invalidates sessions. |
| `CAD_DB_USER` / `CAD_DB_PASS` / `CAD_DB_NAME` | Read by the compose PostgreSQL service and used to derive `CAD_DATABASE_URL`; keep them URL-safe (the setup script uses hex). |
| `CAD_ADMIN_EMAIL` / `CAD_ADMIN_NAME` / `CAD_ADMIN_PASSWORD` | First-account bootstrap. Leave the password empty to skip; set both email and password to create it. |
| `CAD_TLS_MODE` / `CAD_HTTP_BIND` | `auto`, `internal`, or `external`; app bind address (default loopback). |
| `CAD_OAUTH_GITHUB_*` / `CAD_OAUTH_GOOGLE_*` | Client id and secret for human sign-in. Redirect URI: `https://<CAD_PHX_HOST>/auth/user/<provider>/callback`. |
| `CAD_AUTH_*` / `CAD_TOTP_KEY` / `CAD_SESSION_*` | Local password/TOTP policy, TOTP secret encryption, and session lifetimes. Defaults are production-sane; see [spec §12.6](spec.md#126-environment-variable-contract). |
| `CAD_WEBAUTHN_*` | Optional passkey/security-key sign-in (default off). See [Passkeys](#passkeys). |
| `CAD_LLM_API_KEY` | Optional. Required only for melds or docs that need the model; conflict-free melds skip it. |

`CAD_DATABASE_URL` is derived by the reference compose file, so it does not
need to appear in `.env`. Set it explicitly through a compose override if you
use an external database. `CAD_LIVE_VIEW_SALT` and `CAD_TOKEN_SIGNING_SECRET`
fall back to `CAD_SECRET_KEY_BASE`. Local password login is always part of the
build; accounts are created by the operator (there is no public registration),
and TOTP is mandatory for local accounts by default. OAuth and passkeys are
secondary.

## First account

The reference stack creates it automatically. Set `CAD_ADMIN_EMAIL` and
`CAD_ADMIN_PASSWORD` (the setup script generates a strong password and prints
it once). A one-shot `bootstrap` service calls
`Cadence.Server.Release.bootstrap_admin/0` after migrations and before the app
starts. The call is idempotent: if the account exists it is left untouched, and
if the password is empty the service does nothing.

After the first successful sign-in and TOTP enrollment, remove
`CAD_ADMIN_PASSWORD` from `.env`; later `up`s then skip the bootstrap.

Manual equivalent (also useful to reset a password or TOTP later):

```bash
docker compose -f docker-compose.prod.yml exec cadence \
  /app/bin/cadence eval 'Cadence.Server.Release.create_user("you@example.com", "Your Name", "a long password")'
```

`Release.reset_password/2` and `Release.reset_totp/1` work the same way
(`mix cadence.user --reset-password|--reset-totp` is the source-checkout
equivalent). There is no password-reset email.

`CAD_TOTP_KEY` is optional (32 raw bytes, base64, or a passphrase); when absent,
the encryption key is derived from `CAD_SECRET_KEY_BASE`. Rotating either makes
stored TOTP secrets undecryptable — reset them per account.

## Quick start

Automated:

```bash
./scripts/setup-prod.sh cadence.example.com you@example.com --up
```

Manual:

```bash
docker compose -f docker-compose.prod.yml --profile tls up -d --build
```

Use `--profile tls` for `CAD_TLS_MODE=auto`/`internal`; omit it for
`external`. Compose builds `cadence-server:prod`, runs `migrate`
(`/app/bin/cadence eval "Cadence.Server.Release.migrate()"`), runs `bootstrap`,
and starts `cadence` only after both one-shot services exit 0. The same
sequence is in [spec §12.7](spec.md#127-first-boot-sequence-server).

The compose project is `cadence-prod`, distinct from the demo project
(`cadence`), so `down` / `down -v` on one stack cannot touch the other. The
pinned `cadence_actions` volume is shared with the host Docker daemon by design.

## Verify

```bash
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs migrate bootstrap
curl -fsS https://cadence.example.com/health   # {"status":"ok"}
```

With `CAD_TLS_MODE=internal`, use `curl -k` or trust Caddy's root certificate
first (the setup script prints the command). Then sign in at `/sign-in` with the
operator password and the current TOTP code, open `/account` to manage
credentials, `/account/security` if passkeys are enabled, and register a
project from the daemon ([`daemon-setup.md`](daemon-setup.md)).
The daemon's `CAD_SERVER_URL` must be reachable **by the daemon**; public
proposal links come from the server's `CAD_PUBLIC_URL`, so an internal daemon
URL is fine.

The compose app listens on 4000 inside the container and publishes
`CAD_HTTP_PORT` (default 4000) on `CAD_HTTP_BIND` (default `127.0.0.1`).
Caddy reaches it over the compose network; a same-host reverse proxy uses
`127.0.0.1`; a proxy on another host needs `CAD_HTTP_BIND=0.0.0.0`. Running the
image outside compose is supported: set `CAD_HTTP_PORT` and expose the same
port (the image healthcheck follows it).

## Bundled TLS (optional)

The `tls` profile runs `caddy:2-alpine` in front of `cadence`. Select the mode
with `CAD_TLS_MODE`:

| Mode | Use it for | Certificate |
|---|---|---|
| `auto` (default) | A public DNS name with ports 80/443 reachable | Let's Encrypt via Caddy |
| `internal` | A private/LAN hostname | Caddy's local CA |
| `external` | An existing proxy or ingress | None; run without `--profile tls` |

```bash
# Public hostname
CAD_TLS_MODE=auto docker compose -f docker-compose.prod.yml --profile tls up -d

# Private hostname: trust the local CA on clients
CAD_TLS_MODE=internal docker compose -f docker-compose.prod.yml --profile tls up -d
docker compose -f docker-compose.prod.yml exec caddy \
  cat /data/caddy/pki/authorities/local/root.crt > cadence-ca.crt
```

Caddy state lives in the `caddy_data` volume; deleting it discards certificates
(and the local CA, invalidating clients that trusted it). The app port stays on
`CAD_HTTP_BIND` (default `127.0.0.1`), so it is not directly reachable from
outside the host.

## Portainer (paste-a-stack)

`docker-compose.portainer.yml` is self-contained: no `build:` context, no bind
mounts, and no repo-relative files, so it can be pasted into Portainer's stack
editor. It pulls `ghcr.io/vyynl/cadence:latest` and always runs Caddy.
The image is built and pushed by
[`.github/workflows/publish-image.yml`](../.github/workflows/publish-image.yml)
on `master`, `v*` tags, and manual dispatch.

1. **Make the image available.** Run the publish workflow (or push it
   yourself). For a private GHCR package, add registry credentials in
   Portainer: **Registries → Add registry → Custom**, URL
   `https://ghcr.io`, username = your GitHub user, password = a PAT with
   `read:packages`.

   If the first publish fails with `error from registry: denied`, GHCR created
   a package entry that is not linked to the repository (the first-push
   catch-22). Open
   `https://github.com/users/<owner>/packages/container/cadence/settings` and
   either add this repository under **Manage Actions access** with the
   **Write** role, or delete the package and rerun the workflow. Alternatively,
   add a classic PAT with `write:packages` as the `GHCR_TOKEN` repository
   secret; the workflow falls back to it.
2. **Paste the stack.** In Portainer: **Stacks → Add stack → Web editor**, then
   paste `docker-compose.portainer.yml` (or upload it).
3. **Add the environment variables** listed below. Generate the secrets with:
   ```bash
   openssl rand -hex 48   # CAD_SECRET_KEY_BASE
   openssl rand -hex 24   # CAD_DB_PASS
   openssl rand -hex 16   # CAD_ADMIN_PASSWORD
   ```
4. **Deploy** and watch `migrate`, `bootstrap`, `cadence`, and `caddy`.
5. **Sign in** at `https://<CAD_PHX_HOST>/sign-in` with `CAD_ADMIN_EMAIL` and
   the generated admin password, enroll TOTP, then remove
   `CAD_ADMIN_PASSWORD` and redeploy. `bootstrap` is a no-op on later deploys.
6. **Upgrade** with Portainer's **Pull and redeploy** / **Update the stack**;
   the one-shot `migrate` and `bootstrap` services run again safely.

| Variable | Notes |
|---|---|
| `CAD_PHX_HOST` | Hostname only (`cadence.example.com`). |
| `CAD_PUBLIC_URL` | Exact public origin (`https://cadence.example.com`). |
| `CAD_SECRET_KEY_BASE` | 64+ random bytes. |
| `CAD_DB_USER` / `CAD_DB_PASS` / `CAD_DB_NAME` | PostgreSQL credentials; keep `CAD_DB_PASS` URL-safe. |
| `CAD_ADMIN_EMAIL` / `CAD_ADMIN_NAME` / `CAD_ADMIN_PASSWORD` | First account; remove the password after the first sign-in. |
| `CAD_TLS_MODE` | `auto` (public DNS, ports 80/443) or `internal` (private CA). |
| `CAD_SERVER_IMAGE` | Optional image override; default `ghcr.io/vyynl/cadence:latest`. |
| `CAD_ACTIONS_ENABLED` | Set `false` if you do not want Docker actions. |

The Portainer file always includes Caddy. For an existing reverse proxy,
**delete the `caddy` service block** and set `CAD_HTTP_BIND=0.0.0.0` (or attach
the proxy to the stack network). Caddy needs ports 80/443 for `auto` TLS;
`CAD_CADDY_HTTP_PORT` / `CAD_CADDY_HTTPS_PORT` override the published ports but
are only useful with `internal` TLS or an external proxy. This file is for
Docker Standalone stacks; Docker Swarm's legacy deployer does not support
`depends_on` conditions.

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
docker compose -f docker-compose.prod.yml --profile tls up -d --build
```

Omit `--profile tls` when using `--tls external`. `migrate` and `bootstrap`
are one-shot services that run on every `up`; `Ecto.Migrator` skips
already-applied versions and the bootstrap no-ops once the account exists, so a
second run is safe. The app is not started until both succeed.

Manual runs:

```bash
# The compose service (uses the image and the env from compose)
docker compose -f docker-compose.prod.yml run --rm migrate
docker compose -f docker-compose.prod.yml run --rm bootstrap

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
| `caddy_data` | `/data` (Caddy) | TLS certificates and the local CA (bundled profile only). |
| `caddy_config` | `/config` (Caddy) | Caddy runtime configuration. |

The logical names above are what the compose file declares. The pinned action
volume keeps `cadence_actions` exactly; the others are prefixed with the compose
project name, so on disk they are `cadence-prod_cadence_data`,
`cadence-prod_cadence_artifacts`, `cadence-prod_postgres_data`, and (when the
`tls` profile is used) `cadence-prod_caddy_data` / `cadence-prod_caddy_config`
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

The reference stack builds locally by default. The
[publish workflow](../.github/workflows/publish-image.yml) builds and pushes
`ghcr.io/vyynl/cadence` on `master`, `v*` tags, and manual dispatch; it
tags `latest` and `edge` (or the version tag) plus a `sha-<12>` tag. The
Portainer stack consumes that image by default.

To publish manually or to another registry:

```bash
docker build -f docker/Dockerfile -t ghcr.io/you/cadence:1.0.0 .
docker push ghcr.io/you/cadence:1.0.0
```

Then set `CAD_SERVER_IMAGE=ghcr.io/you/cadence:1.0.0` in `.env` and run
`docker compose -f docker-compose.prod.yml pull` (the `cadence` service still
declares a local `build:`; `pull` uses the tagged image). Use the same variable
in Portainer to pin a version instead of `latest`.

CI ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) runs the merge
gate; the separate publish workflow handles registry images. A private GHCR
package needs registry credentials in Portainer (see
[Portainer](#portainer-paste-a-stack)).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Boot raises on a missing env var | `runtime.exs` requires `CAD_SECRET_KEY_BASE`, `CAD_DATABASE_URL`, `CAD_PUBLIC_URL` in `MIX_ENV=prod`. The compose stack derives `CAD_DATABASE_URL` from `CAD_DB_*`; outside compose set it explicitly. |
| `CAD_DEMO_AUTH must never be set…` | This flag no longer exists. Remove it from `.env`; password login is part of every build now. |
| `migrate` exits non-zero | Check `docker compose … logs migrate`; usually the database URL, user, password, or a missing extension. The app will not start until it passes. |
| `bootstrap` exits non-zero | Check `logs bootstrap`: the admin password must satisfy `CAD_AUTH_PASSWORD_MIN_LENGTH` and the email must be present when a password is set. Remove `CAD_ADMIN_PASSWORD` after the first sign-in. |
| Container is `unhealthy` | `docker compose … logs cadence`; the healthcheck calls `/health` on port 4000. A config raise happens before the endpoint binds. |
| Caddy cannot obtain a certificate | `CAD_TLS_MODE=auto` needs a public DNS name and reachable ports 80/443; use `--tls internal` for a private hostname. Check `docker compose … logs caddy`. |
| Browser rejects the internal certificate | Trust `/data/caddy/pki/authorities/local/root.crt` from the `caddy_data` volume on the client machine (the setup script prints the extraction command). |
| Permission denied under `/data` | The volume or bind mount is not writable by the `cadence` uid. See [Volumes and ownership](#volumes-and-ownership). |
| Action run fails `docker_unavailable` | Proxy not reachable or Docker older than 26. Check `CAD_DOCKER_SOCKET` and the proxy logs. |
| Cannot sign in | Use the operator-created password, then the current TOTP code. A local account that has not enrolled is sent to `/sign-in/totp/setup`; an expired pending hand-off returns to `/sign-in`. |
| Lost authenticator or TOTP key rotated | `bin/cadence eval 'Cadence.Server.Release.reset_totp("you@example.com")'`, then sign in and re-enroll. |
| Passkey prompt never appears | Origin is not a secure context, or `CAD_WEBAUTHN_ORIGIN`/`RP_ID` does not match. See [`passkeys.md`](passkeys.md#troubleshooting). |

## Security checklist

- TLS at Caddy (bundled profile) or your proxy; `CAD_PUBLIC_URL` is `https://`.
  Production session cookies are `secure`, so plain HTTP sign-in does not work.
- `.env` is `chmod 600`; never commit it. Remove `CAD_ADMIN_PASSWORD` after the
  first sign-in.
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
