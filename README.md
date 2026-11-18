# Cadence

Cadence is a local-first, self-hosted source control system. Its history is a
DAG of immutable snapshots (one node per commit, no branches), and each user
moves their own pointer through it.

[![CI](https://github.com/vyynl/cadence/actions/workflows/ci.yml/badge.svg)](https://github.com/vyynl/cadence/actions/workflows/ci.yml)
[![Demo smoke](https://github.com/vyynl/cadence/actions/workflows/demo-smoke.yml/badge.svg)](https://github.com/vyynl/cadence/actions/workflows/demo-smoke.yml)
[![Image: ghcr.io/vyynl/cadence](https://img.shields.io/badge/image-ghcr.io%2Fvyynl%2Fcadence-blue)](https://github.com/vyynl/cadence/pkgs/container/cadence)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Why Cadence

- **The DAG replaces branches.** Every snapshot is a node with parents, and
  your session pointer is yours alone. A divergent line is a sibling node, so
  there is no branch to merge and no merge conflict on the DAG itself.
- **Offline-first.** A local daemon watches your project directory, commits
  debounced snapshots to a local Git store, and syncs when the server is
  reachable. Commits, spawns, and switches work with no network.
- **Editor-native.** The Neovim picker renders the DAG and switches, spawns, or
  submits a meld without leaving the editor, over the daemon's Unix socket. A
  terminal UI (`mix cad.tui`) offers the same actions without Neovim, including
  over SSH.

## Run the server

Paste this as your stack. It is [`examples/minimal.yaml`](examples/minimal.yaml),
verbatim. Set `CAD_PUBLIC_URL` and `CAD_ADMIN_EMAIL`, and pin the image by
replacing `:latest` with a release tag or `@sha256:…`.

<details>
<summary><b>docker-compose YAML</b></summary>

```yaml
# Minimal single-host Cadence stack. Paste into a Portainer / TrueNAS stack
# editor, or save as compose.yaml and run `docker compose up -d`.
#
# Set CAD_PUBLIC_URL and CAD_ADMIN_EMAIL (in the stack environment or in .env);
# everything else is generated into a volume on first start. Pin the image by
# replacing :latest with a release tag or a @sha256:… digest.
# For bundled TLS, Docker actions, and a socket proxy see docker-compose.yml.
name: cadence

x-env: &env
  CAD_PUBLIC_URL: ${CAD_PUBLIC_URL:-http://localhost:4000}
  CAD_GIT_STORE_PATH: /data/git
  CAD_ARTIFACT_PATH: /data/artifacts
  CAD_ACTIONS_ENABLED: "false"

services:
  secrets:
    image: alpine:3
    restart: "no"
    volumes:
      - cadence-secrets:/secrets
    command:
      - /bin/sh
      - -c
      - |
        set -eu
        d=/secrets
        gen() { head -c "$$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
        [ -s "$$d/skb" ] || gen 64 > "$$d/skb"
        [ -s "$$d/dbp" ] || gen 24 > "$$d/dbp"
        [ -s "$$d/adm" ] || { gen 16 > "$$d/adm"; echo "First-admin password: $$(cat $$d/adm)"; }
        printf 'CAD_SECRET_KEY_BASE=%s\nCAD_DATABASE_URL=ecto://cadence:%s@postgres:5432/cadence\nCAD_ADMIN_PASSWORD=%s\n' \
          "$$(cat "$$d/skb")" "$$(cat "$$d/dbp")" "$$(cat "$$d/adm")" > "$$d/app.env"
        chmod 644 "$$d"/*

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: cadence
      POSTGRES_DB: cadence
      POSTGRES_PASSWORD_FILE: /secrets/dbp
    volumes:
      - cadence-pg:/var/lib/postgresql/data
      - cadence-secrets:/secrets:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U cadence -d cadence"]
      interval: 5s
      retries: 12

  migrate:
    image: ghcr.io/vyynl/cadence:latest
    restart: "no"
    environment: *env
    volumes: [cadence-secrets:/secrets:ro]
    command:
      - /bin/sh
      - -c
      - set -a; . /secrets/app.env; set +a; exec /app/bin/cadence eval "Cadence.Server.Release.migrate()"
    depends_on:
      postgres: {condition: service_healthy}

  bootstrap:
    image: ghcr.io/vyynl/cadence:latest
    restart: "no"
    environment:
      <<: *env
      CAD_ADMIN_EMAIL: ${CAD_ADMIN_EMAIL:-}
    volumes: [cadence-secrets:/secrets:ro]
    command:
      - /bin/sh
      - -c
      - set -a; . /secrets/app.env; set +a; exec /app/bin/cadence eval "Cadence.Server.Release.bootstrap_admin()"
    depends_on:
      migrate: {condition: service_completed_successfully}

  cadence:
    image: ghcr.io/vyynl/cadence:latest
    restart: unless-stopped
    environment: *env
    # The key base and database URL live in the secrets volume, so source them
    # before exec'ing the release; the image CMD alone has no database URL.
    command:
      - /bin/sh
      - -c
      - set -a; . /secrets/app.env; set +a; exec /app/bin/cadence start
    ports:
      - "127.0.0.1:${CAD_HTTP_PORT:-4000}:4000"
    volumes:
      - cadence-secrets:/secrets:ro
      - cadence-data:/data
    depends_on:
      migrate: {condition: service_completed_successfully}
      bootstrap: {condition: service_completed_successfully}

volumes:
  cadence-secrets:
  cadence-pg:
  cadence-data:
```

</details>

The first-admin password is printed once by the `secrets` service:
`docker compose logs secrets`. In a stack editor it is in that container's logs.
Bundled TLS, Docker actions, and the socket proxy live in
[`docker-compose.yml`](docker-compose.yml); [DEPLOY.md](DEPLOY.md) covers
layouts, backups, and upgrades.

## Run the daemon

The daemon container joins the server's compose network, so it reaches the app
by service name. With the stack above (project `cadence`) the URL is
`http://cadence:4000` and the network is `cadence_default`; the production
`docker-compose.yml` uses project `cadence-prod` and `cadence-prod_default`.
For a remote server, drop `--network` and enter its public origin instead.
Create the state directory first and run both commands as yourself: `setup`
writes `daemon.env` and the database into it, and the daemon must read them
back with the same uid.

```bash
STATE="$HOME/.local/state/cadence"
mkdir -p "$STATE"
docker run --rm -it --user "$(id -u):$(id -g)" \
  -v "$STATE:$STATE" -e CAD_STATE_DIR="$STATE" \
  ghcr.io/vyynl/cadence-daemon:latest setup

docker run -d --name cadence-daemon --restart unless-stopped \
  --user "$(id -u):$(id -g)" --network cadence_default \
  -v "$STATE:$STATE" -e CAD_STATE_DIR="$STATE" \
  -v /home/you/code/my-project:/home/you/code/my-project \
  ghcr.io/vyynl/cadence-daemon:latest

docker exec cadence-daemon bin/cadence_daemon eval \
  'IO.inspect(Cadence.Daemon.Release.register("My Project", "my-project", "/home/you/code/my-project"))'
```

`setup` prompts for the server URL and the API token you minted at
`/auth/tokens/new` (re-authenticate there if it asks), then stores both in the
state volume with mode `0600`, so no secret appears on the command line or in
shell history. The register call is the only step that needs the project path
twice. Give the container a few seconds after `docker run -d`: it migrates and
binds its socket first, so a call that lands too early fails with a connection
error and is worth retrying.

Edit a file in that directory and the project appears at `/p/my-project` within
about 20 seconds. `:CadOpen` in Neovim reads the same DAG: the socket is at
`~/.local/state/cadence/daemon.sock`, where the plugin looks by default.

Remote server instead of a local one? Drop `--network` and give `setup` its
public origin. [DAEMON.md](DAEMON.md) covers the compose and release forms.

## Demo

`docker compose -f docker-compose.demo.yml up --build` starts a seeded server on <http://localhost:4000>; the tour is [DEMO.md](DEMO.md).

## Screenshots

![The Cadence project page: a DAG of snapshots, each node labelled with its flag, beside the file diff for the selected node](.github/assets/dag-ui.png)

![The Neovim DAG picker switching the session pointer, then the server showing the newly synced node](.github/assets/sync.gif)

## Docs

| Document | Contents |
|---|---|
| [DEPLOY.md](DEPLOY.md) | Production stack, layouts, backup and restore, upgrades |
| [DAEMON.md](DAEMON.md) | Installing, configuring, and registering projects with the daemon |
| [DEMO.md](DEMO.md) | The seeded demo stack and guided tour |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The DAG model, the daemon, sync, and auth |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Toolchain, tests, and running the pieces locally |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Symptom, cause, and fix for common failures |
| [CHANGELOG.md](CHANGELOG.md) | Releases and known limitations |
| [SECURITY.md](SECURITY.md) | Supported versions and private vulnerability reporting |

Adopting an existing Git repository is one command: `mix cad.import ~/code/thing`, from a source checkout with the daemon running.

## Contributing

Fork the repository and work on a branch. Run `mix test` from the umbrella root
before opening a pull request; [DEVELOPMENT.md](DEVELOPMENT.md) has the full
gate and the test database. Security reports follow [SECURITY.md](SECURITY.md)
and never go in a public issue.

## See also

- [DEPLOY.md](DEPLOY.md): run the server.
- [ARCHITECTURE.md](ARCHITECTURE.md): how the pieces fit together.
