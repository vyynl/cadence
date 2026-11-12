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

| Account | `cadence-demo` | `meld-review` | `imported-demo` |
|---|---|---|---|
| `owner@demo.local` | owner | owner | owner |
| `approver@demo.local` | viewer | trusted + approver | — (no membership) |
| `viewer@demo.local` | viewer | viewer | — (no membership) |
| `outsider@demo.local` | — (no membership) | — (no membership) | — (no membership) |

Only `owner` and `approver` may approve/reject; `viewer` can read the review
hub; `outsider` can only see public pages. The imported project has no
proposals, so its owner-only membership is enough. Registration is disabled in
every environment — these accounts are seeded.

Passkeys are enabled in this stack for the same accounts:
`CAD_WEBAUTHN_ENABLED=true`, `CAD_WEBAUTHN_RP_ID=localhost`, and
`CAD_WEBAUTHN_ORIGIN=http://localhost:4000`. The demo origin is `localhost`,
which browsers treat as a secure context even over plain HTTP, so the browser's
WebAuthn prompt works without TLS. A real YubiKey must be plugged into the
machine running the browser (or be reachable from it); a browser on another
computer cannot use a key attached to the Docker host. For the same reason the
production deployment requires HTTPS and an explicit public origin — see
[`passkeys.md`](passkeys.md).

## Guided tour

Click order that covers every surface:

1. **Portfolio** — <http://localhost:4000/> lists `Cadence Demo`,
   `Meld Review`, and `Imported Demo`.
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
10. **DAG cap** — open `/p/imported-demo`. It has 160 imported commits, so the
    project page renders the newest 150 and says so; the node pane shows
    provenance (`Imported from git · <author>`; the email appears only to the
    owner, per spec §7.2). The intro animation is skipped above 60 nodes.
11. **History** — from the imported project, open
    `/p/imported-demo/history`. It pages 50 commits at a time (four pages
    here), newest first, with the imported author display name, date, and
    short SHA. Click an old commit to open its snapshot in the node pane.
12. **Imported quarantined commit** — on the last History page, open *Add
    deployment config for CI*. The old snapshot contains a fake `ghp_`-style
    token, so the same push scan used for real nodes opened a critical
    `secret_detected` incident and the public view is quarantined. Sign in as
    owner and **Show raw content** to inspect it; the import did not bypass
    the scan.
13. **Security key / passkey** — sign in as `owner@demo.local`, open **Account**
    in the header, then **Add a security key or passkey**. Give it a name (for
    example *Demo YubiKey*) and complete the browser prompt: touch a plugged-in
    FIDO2 key, use a platform passkey, or choose **Use a phone** and scan the
    browser's own QR code. The key appears in the account list with its
    transport and added date. Now **Sign out**, open `/sign-in`, and choose
    **Sign in with a security key or passkey**; you land back on the portfolio
    signed in. The **Remove** action on `/account/security` is a two-step,
    CSRF-safe flow. If a key is lost, sign in with the demo password and remove
    it there — OAuth or the demo password is the recovery path. A virtual
    authenticator in Chromium DevTools works for a no-hardware tour.
14. **Navigation** — the header shows the signed-in email plus **Sign out**, or
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
- `imported-demo` — 160 nodes shaped exactly like a Git import (original
  40-hex SHAs, preserved parents including one merge, flagless, docs skipped,
  per-commit author/timestamp provenance, tip pinned). The DAG shows the newest
  150 of 160, History pages the rest 50 at a time, and one historical commit
  carries a fake `ghp_`-style token that the real push scan quarantines with an
  open critical `secret_detected` node incident.

Expected totals: 3 projects, 4 accounts, 169 nodes (5 + 4 + 160), 5 proposals,
1 action run.

Re-running is a no-op once all three projects exist, so later changes inside an
already-seeded project (for example the demo action run) need a reset. A
database seeded before the imported project existed is rebuilt automatically
because its project set is incomplete. To rebuild all three projects and their
Git stores from scratch:

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
