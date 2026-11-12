# Demo stack

A one-command, browsable Cadence: PostgreSQL plus a seeded, development-mode
server on <http://localhost:4000>. Use it to try the UI, the DAG, reviews,
imports, and passkeys without setting up OAuth, a daemon, or real history.

**This is not a production deployment.** The image builds with `MIX_ENV=dev`
and compiles in a demo-only password strategy (`CAD_DEMO_AUTH`). The production
stack is `docker-compose.prod.yml` / `docker/Dockerfile`; see
[`deploy.md`](deploy.md) and [spec §12.8](spec.md#128-build-release).

## At a glance

- **Stack:** PostgreSQL, a seeded `cadence_server`, and a Docker socket proxy.
- **Accounts:** four seeded users, password `cadence-demo`.
- **Projects:** three, covering flags, proposals, incidents, action runs, Git
  import, and passkeys.
- **Daemon:** not included. The demo is a server-only stack.
- **Reset:** `docker compose down -v`, or re-seed with `--reset`.

## Prerequisites

- Docker Engine with Compose v2 (`docker compose version`).
- Nothing else: Elixir, PostgreSQL, and the seed all run in containers.

## Quick start

```bash
docker compose up --build
```

The server container migrates the database, seeds the demo data (idempotently),
then boots only `cadence_server` — the daemon is not part of the demo. Wait for
the `Demo data ready` block in the logs, then open <http://localhost:4000>.

```bash
docker compose logs -f server   # follow boot/seed output
docker compose down             # stop; data volumes are kept
docker compose down -v          # stop and wipe PostgreSQL and the Git store
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

Only `owner` and `approver` may approve or reject; `viewer` can read the review
hub; `outsider` can only see public pages. The imported project has no
proposals, so its owner-only membership is enough. Registration is disabled in
every environment; these accounts are seeded.

Passkeys are enabled in this stack for the same accounts:
`CAD_WEBAUTHN_ENABLED=true`, `CAD_WEBAUTHN_RP_ID=localhost`, and
`CAD_WEBAUTHN_ORIGIN=http://localhost:4000`. The demo origin is `localhost`,
which browsers treat as a secure context even over plain HTTP, so the browser's
WebAuthn prompt works without TLS. A real YubiKey must be plugged into the
machine running the browser (or be reachable from it); a browser on another
computer cannot use a key attached to the Docker host. Production requires
HTTPS and an explicit public origin — see [`passkeys.md`](passkeys.md).

## Guided tour

This click order covers every surface:

1. **Portfolio** — <http://localhost:4000/> lists `Cadence Demo`,
   `Meld Review`, and `Imported Demo`.
2. **DAG** — open `/p/cadence-demo`. The preview is the pinned functioning
   node; the DAG shows functioning, broken, sandbox, and in-progress branches.
3. **Repository browser** — click a node, then a folder and a file. The README
   is rendered as Markdown; file content is escaped plain code.
4. **Quarantine** — select the newest node, *Wire up deployment config*. Its
   public view is hidden by an open critical incident. Sign in as
   `owner@demo.local` and use **Show raw content** to inspect it; the incident
   stays open (resolution is acknowledgment, not a fix —
   [spec §6.7](spec.md#67-critical-findings-incidents)).
5. **Review hub** — while signed in, the project header shows **Reviews**. Open
   `/p/meld-review/reviews`.
6. **Review a meld** — open the pending meld, read the file-level diff, then
   **Approve** (as owner or approver). Approval adds the meld node to the DAG and
   pins it.
7. **Rejected / isolated** — the rejected meld is read-only; the isolated result
   has a critical incident and **Approve is hidden** (reject stays available).
8. **Public proposal page** — every proposal has a read-only, identity-free link
   at `/proposals/<token>`. Copy one from the review page or the seed output; it
   works signed out and hides sensitive paths and content.
9. **Run history** — `/p/cadence-demo/runs` lists one seeded finished run; open
   it for the status, exit code, escaped log output, and the **Download raw
   log** link. It was written by the seed, not executed.
10. **DAG cap** — open `/p/imported-demo`. It has 160 imported commits, so the
    project page renders the newest 150 and says so; the node pane shows
    provenance (`Imported from git · <author>`; the email appears only to the
    owner, per [spec §7.2](spec.md#72-ownertrusted-views-authenticated)).
    The intro animation is skipped above 60 nodes.
11. **History** — from the imported project, open
    `/p/imported-demo/history`. It pages 50 commits at a time (four pages here),
    newest first, with the imported author display name, date, and short SHA.
    Click an old commit to open its snapshot in the node pane.
12. **Imported quarantined commit** — on the last History page, open *Add
    deployment config for CI*. The old snapshot contains a fake `ghp_`-style
    token, so the same push scan used for real nodes opened a critical
    `secret_detected` incident and the public view is quarantined. Sign in as
    owner and **Show raw content** to inspect it; the import did not bypass the
    scan.
13. **Security key / passkey** — sign in as `owner@demo.local`, open **Account**
    in the header, then **Add a security key or passkey**. Give it a name (for
    example *Demo YubiKey*) and complete the browser prompt: touch a plugged-in
    FIDO2 key, use a platform passkey, or choose **Use a phone** and scan the
    browser's QR code. The key appears in the account list with its transport
    and added date. Now **Sign out**, open `/sign-in`, and choose **Sign in with
    a security key or passkey**; you land back on the portfolio signed in. The
    **Remove** action on `/account/security` is a two-step, CSRF-safe flow. If a
    key is lost, sign in with the demo password and remove it there — OAuth or
    the demo password is the recovery path. A virtual authenticator in Chromium
    DevTools works for a no-hardware tour.
14. **Navigation** — the header shows the signed-in email plus **Sign out**, or
    **Sign in** when anonymous. Signing out is a two-step, CSRF-safe flow (a
    confirmation page that submits DELETE).

## Seed data

`mix cadence.demo_seed` (run automatically on container boot) creates:

- `cadence-demo` — 5 nodes with real Git snapshots (functioning, broken,
  sandbox, in-progress), one pinned node, a README and source files, one
  secret-tainted node with an open critical incident, and one finished action
  run with a captured log (written by the seed, not executed).
- `meld-review` — three parent nodes plus five proposals: pending meld, pending
  promotion, approved meld (its node was attached by `Proposals.approve/3`),
  rejected meld, and an isolated meld carrying a critical `secret_detected`
  incident.
- `imported-demo` — 160 nodes shaped exactly like a Git import (original 40-hex
  SHAs, preserved parents including one merge, flagless, docs skipped,
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

The task prints project URLs, proposal links, and the account list. It is never
reachable over HTTP.

## Verify

- The log contains the `Demo data ready` block, and
  `docker compose ps` shows `db` and `server` healthy.
- <http://localhost:4000/> lists the three projects.
- `docker compose exec server mix cadence.demo_seed` reports that the seed is
  already complete (a second run is a no-op).
- `/sign-in` shows the password form and, because the demo stack enables
  WebAuthn, the security-key/passkey option.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Port 4000 is already in use | Stop the other process, or change the published port in `docker-compose.yml` and `CAD_WEBAUTHN_ORIGIN` together. |
| Boot waits or the seed never prints `Demo data ready` | `docker compose logs -f server`; the database may still be starting. Confirm `db` is healthy, then restart `server`. |
| Seed data is stale or incomplete after a schema change | `docker compose down -v` wipes the demo volumes; the next `up --build` re-creates and re-seeds everything. |
| `CAD_DEMO_AUTH must never be set…` | You used the production image or a prod boot. The demo flag is build-time only; use `docker-compose.yml` and `docker/Dockerfile.demo`. |
| Sign-in form is missing | The image was rebuilt without `--build-arg CAD_DEMO_AUTH=true`. Rebuild with `docker compose up --build`. |
| Passkey prompt never appears | Use `http://localhost:4000`, not a LAN hostname, and keep `CAD_WEBAUTHN_RP_ID=localhost`. See [`passkeys.md`](passkeys.md#troubleshooting). |
| CSS edits do not appear | Only `priv/static/css` is bind-mounted. Rebuild the image after changing anything else. |

## Iterate on style and templates

- **CSS** is bind-mounted from `apps/cadence_server/priv/static/css/`. Edit
  `app.css` on the host and refresh the browser.
- **Templates and LiveViews** recompile on the next request (`code_reloader` is
  on in dev). Edit `.heex`/`.ex` files and refresh.
- Push-based live reload is not wired (it would add the `phoenix_live_reload`
  dependency, which is not in [spec §11](spec.md#11-technology-stack));
  a refresh is enough for the demo.

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

## Related docs

- [Daemon setup](daemon-setup.md) — connect a real local daemon.
- [Import a Git repository](import.md) — the workflow behind `imported-demo`.
- [Security keys and passkeys](passkeys.md) — the feature behind step 13.
- [Production deployment](deploy.md) — the real stack.
- [Spec §12.4](spec.md#124-reference-compose-stack) — the compose
  contract.
