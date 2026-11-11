# Demo stack

A one-command, browsable Cadence: Postgres plus a seeded, dev-mode server on
<http://localhost:4000>. It exists so style, layout, copy and flows can be
poked at in a browser without setting up OAuth, a daemon, or real history.

**This is not a production deployment.** The image builds with `MIX_ENV=dev`
and compiles in a demo-only password strategy (`CAD_DEMO_AUTH`). The production
stack is `docker-compose.prod.yml` / `docker/Dockerfile`; see `docs/deploy.md`
and spec §12.8.

## Prerequisites

- Docker Engine with Compose v2 (`docker compose version`)
- Nothing else — Elixir, Postgres and the seed all run in containers

## Start

```bash
docker compose up --build
```

The server container migrates the database, seeds the demo data (idempotent),
then boots only `cadence_server` — the daemon is not part of the demo. Wait for
the `Demo data ready` block in the logs, then open <http://localhost:4000>.

```bash
docker compose logs -f server   # follow boot/seed output
docker compose down             # stop; data volumes are kept
docker compose down -v          # stop and wipe Postgres + Git store
```

## Accounts

Every account uses the password **`cadence-demo`**. Sign in at
<http://localhost:4000/sign-in>.

| Account | `cadence-demo` | `meld-review` |
|---|---|---|
| `owner@demo.local` | owner | owner |
| `approver@demo.local` | viewer | trusted + approver |
| `viewer@demo.local` | viewer | viewer |
| `outsider@demo.local` | — (no membership) | — (no membership) |

Only `owner` and `approver` may approve/reject; `viewer` can read the review
hub; `outsider` can only see public pages. Registration is disabled in every
environment — these accounts are seeded.

## Guided tour

Click order that covers every surface:

1. **Portfolio** — <http://localhost:4000/> lists `Cadence Demo` and
   `Meld Review`.
2. **DAG** — open `/p/cadence-demo`. The preview is the pinned functioning
   node; the DAG shows functioning, broken, sandbox and in-progress branches.
3. **Repository browser** — click a node, then a folder and a file. The README
   is rendered as Markdown; file content is escaped plain code.
4. **Quarantine** — select the newest node, *Wire up deployment config*. Its
   public view is hidden by an open critical incident. Sign in as
   `owner@demo.local` and use **Show raw content** to inspect it; the incident
   stays open (resolution is acknowledgment, not a fix — spec §6.7).
5. **Review hub** — while signed in, the project header shows **Reviews**.
   Open `/p/meld-review/reviews`.
6. **Review a meld** — open the pending meld, read the file-level diff, then
   **Approve** (as owner or approver). Approval adds the meld node to the DAG
   and pins it.
7. **Rejected / isolated** — the rejected meld is read-only; the isolated
   result has a critical incident and **Approve is hidden** (reject stays
   available).
8. **Public proposal page** — every proposal has a read-only, identity-free
   link at `/proposals/<token>`. Copy one from the review page or from the
   seed output; it works signed out and hides sensitive paths and content.
9. **Run history** — `/p/cadence-demo/runs` lists one seeded finished run;
   open it for the status, exit code, escaped log output, and the
   **Download raw log** link. It was written by the seed, not executed.
10. **Navigation** — the header shows the signed-in email plus **Sign out**, or
    **Sign in** when anonymous. Signing out is a two-step, CSRF-safe flow (a
   confirmation page that submits DELETE).

## Seed data

`mix cadence.demo_seed` (run automatically on container boot) creates:

- `cadence-demo` — 5 nodes with real Git snapshots (functioning, broken,
  sandbox, in-progress), one pinned node, a README and source files, one
  secret-tainted node with an open critical incident, and one finished action
  run with a captured log (written by the seed, not executed).
- `meld-review` — three parent nodes plus five proposals: pending meld,
  pending promotion, approved meld (its node was attached by
  `Proposals.approve/3`), rejected meld, and an isolated meld carrying a
  critical `secret_detected` incident.

Re-running is a no-op, so a database seeded by an older image does not pick up
new seed changes (for example the demo action run). To rebuild from scratch:

```bash
docker compose exec server mix cadence.demo_seed --reset
```

The task prints project URLs, proposal links and the account list. It is never
reachable over HTTP.

## Iterate on style and templates

- **CSS** is bind-mounted from `apps/cadence_server/priv/static/css/`. Edit
  `app.css` on the host and refresh the browser.
- **Templates and LiveViews** recompile on the next request (`code_reloader` is
  on in dev). Edit `.heex`/`.ex` files and refresh.
- Push-based live reload is not wired (it would add the
  `phoenix_live_reload` dependency, which is not in spec §11); a refresh is
  enough for the demo.

Rebuild the image after changing `mix.exs`, config, or anything outside
`priv/static/css`.

## Security note

The password strategy is compiled in only when `CAD_DEMO_AUTH=true` **at build
time** (`Application.compile_env`). A production build without the flag does
not contain the strategy, and `config/runtime.exs` raises if a prod boot sees
the flag set. Registration is disabled. The demo password is intentionally
public; never reuse this image or these accounts outside a local demo.

## Running without Docker

```bash
export CAD_DEMO_AUTH=true        # compile-time gate: must be set before compiling
export CAD_DATABASE_URL="ecto://postgres:postgres@localhost:5432/cadence_dev"
export CAD_GIT_STORE_PATH="$HOME/.local/state/cadence/server-git"
mix deps.get && mix compile
mix ecto.migrate -r Cadence.Server.Repo
mix cadence.demo_seed
mix run --no-start --no-halt -e 'Application.ensure_all_started(:cadence_server)'
```

The last command starts the server only; omit `--no-start`/`--no-halt` and use
`mix phx.server` if you also want the daemon.
