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
CAD_SERVER_IMAGE=ghcr.io/vyynl/cadence:1.2.3 docker compose pull
CAD_SERVER_IMAGE=ghcr.io/vyynl/cadence:1.2.3 docker compose up -d
```

`migrate` and `bootstrap` run on every `up` and are idempotent, so the app never
starts against an unmigrated database. Rollback is not automated: restore a
backup, and never point two running stacks at one database.

## See also

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): first boot, `/health` 502, passkeys.
- [README.md](README.md): what Cadence is and how to run it locally.
