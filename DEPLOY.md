# Deploying Cadence

One Compose file runs the published image — no local build, no host scripting,
no `openssl`; secrets are generated in a volume on first start. Configuration is
[`.env.example`](.env.example).

If the GHCR package is private — a setting independent of the repository's own
visibility — log in once or the pull fails with `unauthorized`:

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin
```

That token needs `read:packages` and nothing else. Making the package public in
its GitHub settings removes this step for every operator.

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
| One machine, just evaluating | [`examples/localhost.yaml`](examples/localhost.yaml) |

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

- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — first boot, `/health` 502, passkeys.
- [README.md](README.md) — what Cadence is and how to run it locally.
