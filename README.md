# Cadence

A local-first, self-hosted source control system built around a DAG of
session nodes rather than Git branches.

- **Canonical spec:** [docs/spec.md](docs/spec.md)
- **Agent conventions:** [AGENTS.md](AGENTS.md)
- **Status:** early scaffolding

## Quick overview

Cadence consists of three Elixir apps in an umbrella:

- `cadence_shared` — schemas, sync protocol, GitStore, LLM client
- `cadence_daemon` — local process: watcher, commit queue, Unix socket
- `cadence_server` — Phoenix: web UI, sync endpoint, meld worker

See the spec for architecture, data model, and build order.
