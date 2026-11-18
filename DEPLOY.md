# Deploying Cadence

One Compose file runs the published image: no local build, no host scripting,
no `openssl`; secrets are generated in a volume on first start. Configuration is
[`.env.example`](.env.example).

```bash
cp .env.example .env         # set CAD_PUBLIC_URL and CAD_ADMIN_EMAIL
docker compose up -d
docker compose logs secrets  # first-admin password, printed once
```

Then sign in as `CAD_ADMIN_EMAIL`, enroll TOTP, and delete `CAD_ADMIN_PASSWORD`.

## Layouts

| You have | Run |
|---|---|
| A DNS name and ports 80/443 free | `docker compose --profile tls up -d` |
| TrueNAS SCALE or Portainer, paste-a-stack | [`examples/truenas.yaml`](examples/truenas.yaml) |
| An existing reverse proxy | [`examples/behind-existing-proxy.yaml`](examples/behind-existing-proxy.yaml) |
| One machine, evaluation only | [`examples/localhost.yaml`](examples/localhost.yaml) |

## Image sources

GHCR is canonical: `ghcr.io/vyynl/cadence` (server) and
`ghcr.io/vyynl/cadence-daemon`. The same images are mirrored to Docker Hub
(`vyynl/cadence`, `vyynl/cadence-daemon`) by
`.github/workflows/publish-dockerhub.yml`, which needs the repository secrets
`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`. Both channels carry the same tags:
`latest` and `edge` on `master`, `v*` and `latest` on a version tag, and
`sha-<12>` on every build. Point the stack at the mirror with
`CAD_SERVER_IMAGE=docker.io/vyynl/cadence:latest`.

## Public domain with private access

The public origin and the address you work at can differ. `CAD_PUBLIC_URL` is
the origin the server **publishes**: proposal links, canonical metadata, the
passkey origin, and the only host whose session cookie is marked `Secure`. It
does not have to be where you sign in, and it is not where the daemon syncs.

Three independent settings make the split work:

| Setting | Lives on | Meaning |
|---|---|---|
| `CAD_PUBLIC_URL` | server | the published origin; generated links always use it |
| `CAD_SESSION_COOKIE_SECURE` | server | `public` (default) marks only that host, `always`, or `never` |
| `CAD_SERVER_URL` | daemon | where the daemon syncs; a private address is fine |

The daemon side needs nothing extra: proposal links arrive from the server
already built from `CAD_PUBLIC_URL`, so `:CadProposals` and share links stay
public while sync runs over the private address.

### Tailscale

Recommended, because the certificate is trusted, so the cookie rule never comes
up:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:4000
# browse https://<node>.<tailnet>.ts.net
```

Requires HTTPS certificates enabled for the tailnet (admin console, DNS). Serve
is tailnet-only; `tailscale funnel` would publish it instead.

### LAN over HTTP

```bash
CAD_HTTP_BIND=0.0.0.0      # in .env; exposes plain HTTP, so firewall it
CAD_SESSION_COOKIE_SECURE=public    # the default, stated for clarity
# browse http://192.168.1.10:4000
```

A private host gets a **non-`Secure`** cookie by design: a browser will not keep
a `Secure` cookie over plain HTTP, and the alternative is a page that loads with
every panel stuck on "Loading…". Keep that leg on a network you trust, or use
Tailscale/your own TLS and leave the setting alone.

### Daemon

```bash
CAD_SERVER_URL=http://100.107.198.51:4000   # tailnet address, no trailing slash
CAD_AUTH_TOKEN=cad_...
```

`http` also switches the notification socket to `ws`. The daemon container must
be able to route to the address (the tailnet IP works from a bridge network;
`localhost` does not mean the server container).

## Backup and restore

```bash
docker compose exec postgres pg_dump -U cadence cadence > cadence.sql
docker run --rm -v cadence-prod_cadence_data:/data -v "$PWD":/backup alpine \
  tar czf /backup/cadence-data.tgz -C /data .
```

Dump and Git objects belong together, or the metadata points at data you no
longer have. Restore into an empty stack: `up -d postgres`, `psql` the dump,
untar the archive, `up -d`.

## Upgrade

```bash
CAD_SERVER_IMAGE=ghcr.io/vyynl/cadence:v1.1.0 docker compose pull
CAD_SERVER_IMAGE=ghcr.io/vyynl/cadence:v1.1.0 docker compose up -d
```

Tag names keep the `v` (the workflow publishes the tag exactly as pushed), so
`:v1.1.0` is a release; `:latest` moves on every `master` build and every
version tag. A digest (`@sha256:…`) is the immutable choice.

`migrate` and `bootstrap` run on every `up` and are idempotent, so the app never
starts against an unmigrated database. Rollback is not automated: restore a
backup, and never point two running stacks at one database.

## See also

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): first boot, `/health` 502, passkeys.
- [README.md](README.md): what Cadence is and how to run it locally.
