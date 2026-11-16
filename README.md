# Cadence

Cadence is a local-first, self-hosted source control system. Its history is a
DAG of immutable snapshots — one node per commit, no branches — and each user
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
  submits a meld without leaving the editor, over the daemon's Unix socket.

## Deploy in 60 seconds

```bash
cp .env.example .env    # set CAD_PUBLIC_URL and CAD_ADMIN_EMAIL
docker compose up -d
```

You get the server, PostgreSQL, and a one-shot migration and first-admin
bootstrap; `docker compose logs secrets` prints the generated admin password
once. Add `--profile tls` for bundled Caddy. Layouts, backups, and upgrades are
in [DEPLOY.md](DEPLOY.md); paste-ready variants live in
[`examples/`](examples/).

## Connect a daemon

```bash
cp .env.daemon.example .env.daemon    # set CAD_SERVER_URL and CAD_AUTH_TOKEN
docker compose -f docker-compose.daemon.yml up -d
```

The first run needs a one-time migration; [DAEMON.md](DAEMON.md) covers it, the
host release artifact, and project registration.

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

- [DEPLOY.md](DEPLOY.md) — run the server.
- [ARCHITECTURE.md](ARCHITECTURE.md) — how the pieces fit together.
