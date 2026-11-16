# Development

## Toolchain

Elixir `~> 1.20` on OTP 29 — the pair CI and `docker/Dockerfile` use. Docker is
needed for the test database and the demo stack; `mix deps.get` fetches from the
umbrella root.

Server tests need PostgreSQL on `localhost:55432`, matching `config/test.exs`:

```bash
docker run --rm -d --name cadence-test-pg \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=cadence_test \
  -p 55432:5432 postgres:16-alpine
```

## Tests

```bash
mix test                              # the whole suite
(cd apps/cadence_shared && mix test)  # one app
mix test --cover                      # 80% floor per app
```

The merge gate is formatting, both compiles, and the suite:

```bash
mix format --check-formatted &&
mix compile --warnings-as-errors &&
MIX_ENV=prod mix compile --warnings-as-errors &&
mix test
```

`credo` and `dialyzer` are not configured in this umbrella.

## Local stacks

A seeded, browsable server on <http://localhost:4000>:

```bash
docker compose -f docker-compose.demo.yml up --build
```

Sign in as `owner@demo.local` / `cadence-demo`; [DEMO.md](DEMO.md) has the TOTP
command and the tour.

A daemon against that server — [DAEMON.md](DAEMON.md) covers project
registration and token minting:

```bash
cp .env.daemon.example .env.daemon    # set CAD_SERVER_URL and CAD_AUTH_TOKEN
docker compose -f docker-compose.daemon.yml run --rm daemon bin/cadence_daemon eval "Cadence.Daemon.Release.migrate()"
docker compose -f docker-compose.daemon.yml up -d
```

## See also

- [ARCHITECTURE.md](ARCHITECTURE.md) — the system the tests exercise.
- [README.md](README.md) — project overview.
