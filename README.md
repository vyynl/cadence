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
  # Optional AI features. A blank key disables them; the full reference is
  # .env.example. The server uses these for meld conflict resolution.
  CAD_LLM_PROVIDER: ${CAD_LLM_PROVIDER:-deepseek}
  CAD_LLM_API_KEY: ${CAD_LLM_API_KEY:-}
  CAD_LLM_MODEL: ${CAD_LLM_MODEL:-deepseek-chat}
  CAD_LLM_BASE_URL: ${CAD_LLM_BASE_URL:-https://api.deepseek.com}

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

The daemon is the local half: it watches your project directories, commits
snapshots locally, and syncs them to the Cadence server you already deployed.
It does not need a server on the same machine, and the commands below target a
remote server by default.

The directory you start from is the **hub**: every direct child directory
becomes a project automatically, so a new folder under it is watched and synced
without a separate register call. Run these commands from the directory you
want the daemon to serve as the hub:

```bash
STATE="$HOME/.local/state/cadence"
mkdir -p "$STATE"
docker run --rm -it --user "$(id -u):$(id -g)" \
  -v "$STATE:$STATE" -e CAD_STATE_DIR="$STATE" \
  -v "$PWD:$PWD" -e "CAD_PROJECTS_ROOT=$PWD" \
  ghcr.io/vyynl/cadence-daemon:latest setup

docker run -d --name cadence-daemon --restart unless-stopped \
  --user "$(id -u):$(id -g)" \
  -v "$STATE:$STATE" -e CAD_STATE_DIR="$STATE" \
  -v "$PWD:$PWD" \
  ghcr.io/vyynl/cadence-daemon:latest
```

Mint a token on the server at `/auth/tokens/new` (sign in first; the page asks
for your password and TOTP code again if the sudo window has expired). Create
the state directory first and run both commands as yourself: `setup` writes
`daemon.env` and the database into it, and the daemon must read them back with
the same uid. The hub is mounted at the same absolute path inside and outside
the container; the state directory is a separate mount.

`setup` prompts for the server URL, the API token, and an optional LLM API key
(with provider, model, and base URL defaults), then stores them in the state
directory with mode `0600`, so no secret appears on the command line or in
shell history. `CAD_PROJECTS_ROOT` is taken from the command and stored in
`daemon.env`, so the hub is remembered across restarts and upgrades. Leave the
LLM key blank to skip AI configuration (a re-run keeps an existing key unless
you replace it). Use the origin you reach the server at, for example
`https://cadence.example.com`, or a LAN or Tailscale address such as
`http://100.107.198.51:4000`; plain HTTP is fine inside a private network or
tunnel. `localhost` does not mean the server container, so use a routable
address unless the daemon runs in the server's network namespace. It finishes
by calling the server: you should see `server authenticated`. A `401` means the
token is wrong; `cannot reach ...` means the URL is wrong or unreachable from
the container.

New direct children of the hub are registered automatically. A child that is a
Git repository imports its history (original SHAs, parents, authors) and its
nodes carry the `imported` flag; a plain directory gets one imported snapshot of
its current tree, then the normal watcher. The project page and portfolio show
an imported badge. To add a project outside the hub, mount its parent and
register it explicitly. The path must be absolute. From a checkout,
`mix deps.get && mix compile` once (a fresh clone has neither), then:

```bash
mix cad.register "My Project" my-project "$HOME/code/my-project"
```

No Elixir toolchain? The container can register the directory itself; the form
is in [DAEMON.md](DAEMON.md#register-a-project), and
`scripts/cadence-up.sh <dir>` needs only Docker and does setup, start, and
register in one step.

Edit a file in it and the project appears at `/p/my-project` within about 20
seconds. `mix cad.tui` lists the registered projects and drives their DAGs
without Neovim; [DAEMON.md](DAEMON.md#register-a-project) has the container and
release forms.

The daemon migrates before it binds its socket, so a register call in the first
few seconds after `docker run -d` fails with a connection error and only needs a
retry. `:CadOpen` in Neovim reads the same DAG: the socket is at
`~/.local/state/cadence/daemon.sock`, where the plugin looks by default.

**Server on the same machine?** The all-in-one evaluation stack above is the
only case that needs a Docker network. Add `--network cadence_default` to both
`docker run` commands and enter `http://cadence:4000` for `setup`;
`docker-compose.yml` uses `cadence-prod_default` instead. A normal install runs
the daemon on the machine with your code and omits both. The server's
`CAD_PUBLIC_URL` still decides the links, so a LAN or Tailscale sync address
keeps shares public while sync stays private; [DAEMON.md](DAEMON.md) covers the
compose and release forms, and
[DEPLOY.md](DEPLOY.md#public-domain-with-private-access) covers signing in over
the private address.

## AI features (optional)

Generated commit messages, doc automation, and meld conflict resolution use an
OpenAI-compatible model. The minimal stack above leaves `CAD_LLM_API_KEY` blank,
which disables them; set the four `CAD_LLM_*` variables from
[`.env.example`](.env.example) in the stack environment to turn them on. The
server needs the key for melds; the daemon needs it for commit messages and
docs, and its `setup` stores it in `daemon.env` like the server token.

Without a key, commits still land with the default message, doc jobs are
skipped, and a union with conflicts fails with an incident; a union with no
conflicts still resolves. `CAD_LLM_BASE_URL` points at any compatible endpoint,
so a local model works too.

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
