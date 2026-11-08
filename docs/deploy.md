# Production deployment

The server ships as a self-contained Elixir release inside the image built from
`docker/Dockerfile` (spec §12.3, §12.8). `docker-compose.prod.yml` is the
reference stack from spec §12.4 plus a one-shot `migrate` service.

This is **not** the demo stack. The demo (`docker-compose.yml`,
`docker/Dockerfile.demo`) builds with `MIX_ENV=dev`, compiles in a password
strategy, seeds fake data, and exists for browsing the UI. See `docs/demo.md`.

---

## Prerequisites

- Docker Engine 26 or newer (the action runner uses the `volume-subpath` mount
  option, Docker API `v1.45`) and Docker Compose v2.17+.
- A TLS-terminating reverse proxy (Caddy, nginx, TrueNAS built-in). Cadence
  serves plain HTTP on `CAD_HTTP_PORT`; TLS is the proxy's job.
- Postgres 16 (the reference stack runs it in a container).
- For Docker actions: a filesystem with a size limit for `CAD_ACTIONS_VOLUME_PATH`
  (§8.4), and the socket **proxy** — never the raw socket.

## Secrets

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
| `CAD_DB_USER` / `CAD_DB_PASS` / `CAD_DB_NAME` | Read by the compose Postgres service; keep them consistent with `CAD_DATABASE_URL`. |
| `CAD_OAUTH_GITHUB_*` / `CAD_OAUTH_GOOGLE_*` | Client id/secret for human sign-in. Redirect URI: `https://<CAD_PHX_HOST>/auth/user/<provider>/callback`. |
| `CAD_LLM_API_KEY` | Required for melds/docs that need the model; conflict-free melds skip it. |

`CAD_LIVE_VIEW_SALT` and `CAD_TOKEN_SIGNING_SECRET` fall back to
`CAD_SECRET_KEY_BASE`. The production image has **no password strategy** — users
sign in through OAuth.

## First boot

```bash
docker compose -f docker-compose.prod.yml up -d --build
```

Compose builds `cadence-server:prod`, runs the `migrate` service
(`/app/bin/cadence eval "Cadence.Server.Release.migrate()"`), and starts
`cadence` only after the migration exits 0. The same command appears in spec
§12.7.

The compose project is `cadence-prod`, distinct from the demo project
(`cadence`), so `down` / `down -v` on one stack cannot touch the other. The
pinned `cadence_actions` volume is shared with the host Docker daemon by design.

Check it:

```bash
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs migrate
curl -fsS https://cadence.example.com/health   # {"status":"ok"}
```

Then sign in at `/sign-in` and register a project from the daemon
(`docs/daemon-setup.md`). The daemon's `CAD_SERVER_URL` must be the public URL.

The compose app listens on 4000 inside the container and publishes
`CAD_HTTP_PORT` (default 4000). Point the reverse proxy at that port. Running the
image outside compose is supported: set `CAD_HTTP_PORT` and expose the same port
(the image healthcheck follows it).

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
| `cadence_data` | `/data` | Git object stores (loose objects + packs). |
| `cadence_artifacts` | `/data/artifacts` | Action logs and collected artifacts. |
| `cadence_actions` | `/data/actions` | Staged snapshots and `/out` subpaths for action containers (`CAD_ACTIONS_VOLUME`). |
| `postgres_data` | `/var/lib/postgresql/data` | Postgres. |

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
- The socket proxy is **root-equivalent** on the host (§8.4). The app reaches it
  at `http://docker-proxy:2375`; action containers run with no network by default
  and cannot reach it.
- Point `CAD_ACTIONS_VOLUME_PATH` at a filesystem with a size limit: an action can
  fill it during its timeout; post-exit collection caps only the copy (§8.3).
- Project `Dockerfile` `FROM` pulls run on the host Docker daemon, so treat them
  as able to reach any registry the daemon can reach.

## Building and publishing the image

The compose file builds locally. To publish a versioned image:

```bash
docker build -f docker/Dockerfile -t ghcr.io/you/cadence-server:0.1.0 .
docker push ghcr.io/you/cadence-server:0.1.0
```

Then set `CAD_SERVER_IMAGE=ghcr.io/you/cadence-server:0.1.0` in `.env` and run
`docker compose -f docker-compose.prod.yml pull` (the `cadence` service still
declares a local `build:`; `pull` uses the tagged image). There is no CI
pipeline in this repository.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Boot raises on a missing env var | `runtime.exs` requires `CAD_SECRET_KEY_BASE`, `CAD_DATABASE_URL`, `CAD_PUBLIC_URL` in `MIX_ENV=prod`. Set them in `.env`. |
| `CAD_DEMO_AUTH must never be set…` | The demo flag is compile-time only. Unset it in the environment and rebuild without `--build-arg CAD_DEMO_AUTH=…` (the Dockerfile rejects it). |
| `migrate` exits non-zero | Check `docker compose … logs migrate`; usually the database URL/user/password or a missing extension. The app will not start until it passes. |
| Container is `unhealthy` | `docker compose … logs cadence`; the healthcheck calls `/health` on port 4000. A config raise happens before the endpoint binds. |
| Permission denied under `/data` | The volume or bind mount is not writable by the `cadence` uid. See *Volumes and ownership*. |
| Action run fails `docker_unavailable` | Proxy not reachable or Docker older than 26. Check `CAD_DOCKER_SOCKET` and proxy logs. |
| Sign-in shows no form | Expected in production: only OAuth strategies are compiled in. Configure an OAuth client. |

## Security checklist

- TLS at the proxy; `CAD_PUBLIC_URL` is `https://`.
- `.env` is `chmod 600`; never commit it.
- Docker socket via the allowlisted proxy only; never bind the raw socket into
  the app container on a reachable host.
- Review `CAD_ACTIONS_*` limits before enabling actions; keep the artifact
  volume size-limited.
- Back up `postgres_data` and `cadence_data` together (metadata + object store).
  There is no built-in backup task yet (spec §16).
