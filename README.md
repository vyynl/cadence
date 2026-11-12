# Cadence

A local-first, self-hosted source control system built around a DAG of
session nodes rather than Git branches.

- **Canonical spec:** [docs/spec.md](docs/spec.md)
- **Contributing:** [CONTRIBUTING.md](CONTRIBUTING.md)
- **Status:** 1.0.0 — the planned build order is complete; see
  [docs/release-notes.md](docs/release-notes.md) for the release summary,
  upgrade notes, and known limitations.

## Quick overview

Cadence consists of three Elixir apps in an umbrella:

- `cadence_shared` — schemas, sync protocol, GitStore, LLM client
- `cadence_daemon` — local process: watcher, commit queue, Unix socket
- `cadence_server` — Phoenix: web UI, sync endpoint, meld worker

See the spec for architecture, data model, and build order.

## Continuous integration

The merge gate is one workflow: [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
It runs on every push to `master`, every pull request, and on demand with a
read-only token, a Postgres 16 service on port 55432, and Elixir 1.20 / OTP 29
(matching the minor version of the `docker/Dockerfile` toolchain):

- `mix format --check-formatted`
- dev and prod compiles with `--warnings-as-errors`
- `mix test`, then `mix test --cover` at an **80% floor** per app
  (`test_coverage` in each `mix.exs`). Mix exits `3` for a coverage miss and
  `2` for a test failure (`--exit-status` defaults to 2).
- `mix hex.audit` and `mix deps.unlock --check-unused`
- `mix sobelow --exit medium` from `apps/cadence_server`
- `mix deps.audit --ignore-file .mix_audit.ignore` from the umbrella root,
  followed by an assertion that the advisory database is populated —
  `mix_audit` passes silently when its git clone is missing
  (see `.mix_audit.ignore`).

Reproduce the gate locally. Start the test database first — same port, user,
password, and database as the CI service (also in CONTRIBUTING.md):

```bash
docker run --rm -d --name cadence-test-pg \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=cadence_test \
  -p 55432:5432 postgres:16-alpine
```

Then run the gate from the umbrella root:

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=prod mix compile --warnings-as-errors
mix test
mix test --cover
mix hex.audit
mix deps.unlock --check-unused
(cd apps/cadence_server && mix sobelow --exit medium)
mix deps.audit --ignore-file .mix_audit.ignore
test -n "$(find ~/.local/share/elixir-security-advisories-mirego/packages \
  -name '*.yml' -print -quit)"
```

Operator setup: push this repository to GitHub with Actions enabled. The
workflow needs no secrets and no hosted services beyond GitHub Actions itself.
