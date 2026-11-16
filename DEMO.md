# Demo

[![Demo smoke](https://github.com/vyynl/cadence/actions/workflows/demo-smoke.yml/badge.svg)](https://github.com/vyynl/cadence/actions/workflows/demo-smoke.yml)

A seeded, development-mode Cadence on <http://localhost:4000>: PostgreSQL plus a
`MIX_ENV=dev` server that migrates and seeds itself on boot. It is not a
deployment; the production stack is `docker-compose.yml`.

```bash
docker compose -f docker-compose.demo.yml up -d --build
docker compose -f docker-compose.demo.yml logs -f server
```

The first build compiles the whole application, so it takes **10–15 minutes**
before anything appears. When the logs show `Demo data ready`, open
<http://localhost:4000> and sign in at `/sign-in` as `owner@demo.local` with
password `cadence-demo`. The form then asks for a TOTP code:

```bash
docker compose -f docker-compose.demo.yml exec server mix cadence.totp --email owner@demo.local
```

`docker compose -f docker-compose.demo.yml down -v` wipes the database and the
Git store. CI boots this stack on pull requests and pushes to `master`:
[`demo-smoke.yml`](.github/workflows/demo-smoke.yml).

## See also

- [DEPLOY.md](DEPLOY.md): the production stack.
- [README.md](README.md): what Cadence is.
