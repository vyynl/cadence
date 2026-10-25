# Phase 3 roadmap — Web UI & Portfolio

> Status: **approved 2026-10-24**. This is the session-by-session plan for
> Phase 3. `docs/spec.md` §7/§13/§16 are canonical; this file tracks the
> execution order and per-session acceptance.

## Decisions (approved)

| # | Decision | Resolution |
|---|---|---|
| 1 | Public DAG visibility | Preview node only for anonymous visitors; full DAG for authenticated members |
| 2 | Web DAG Y-axis | Topological depth with fixed spacing; timestamps in hover metadata |
| 3 | 3a view technology | Dead views (controller + HEEx), no JS asset pipeline |
| 4 | Routing | `/p/:slug`, `/p/:slug/n/:id`, portfolio index `/` |
| 5 | Docs source | README only in Phase 3; `docs_schema` in Phase 5 |
| 6 | Project discoverability | All projects public by default; `visibility` column deferred |
| 7 | Review/promotion UI | Deferred to Phase 4; optional read-only placeholder only |

## Session plan

| Session | Slice | Deliverable | Exit criteria |
|---|---|---|---|
| 0 | Decisions + docs | Spec updates, this roadmap, docs commit | Docs committed; no app code |
| 1 | 3a | Public `/p/:slug` page, `Portfolio`, `GitStore` path reader, HTML layout/errors | Seeded project renders HTML; tests green |
| 2 | 3b | Pure DAG layout + server-rendered SVG | Branch/meld/wrap tested; visibility applied |
| 3 | 3c | Portfolio index + README via `MDEx` | Index lists projects; safe Markdown; edge cases |
| 4 | 3d | Session/role gating, owner pin/unpin | Owner can pin; anonymous cannot; no leakage |
| 5 | Close | Defer 3e, final spec/progress update | Full suite + prod compile green |

### Session 1 — 3a

- Declare direct server deps: `phoenix_html`, `phoenix_live_view` (dead views;
  no JS pipeline).
- `Cadence.ServerWeb`: `html_helpers`, layouts, minimal components, HTML error
  renderer.
- `Cadence.Server.Portfolio`: `get_project_by_slug/1`, `list_nodes/1`,
  `preview_node/1`, `membership_for/2`.
- `Cadence.Shared.GitStore.read_path/3`: commit → tree → blob read with a size
  cap and safe path traversal.
- Routes: public browser pipeline, `GET /p/:slug`.
- Tests: `Portfolio`, `GitStore.read_path`, ConnTest 200/404.
- Acceptance: read-only HTML page for a seeded project, no JavaScript.

### Session 2 — 3b

- `Cadence.ServerWeb.DAGLayout` pure module: depths, layer order, coordinates,
  elbow edges, wrap marker.
- SVG component: flag colors, pinned ring, child-flag edges, accessible titles.
- Node links to `/p/:slug/n/:id`; CSS/`<title>` hover. No LiveView unless
  interaction requires it; no `esbuild` without a spec §11 update.
- Tests: linear/branch/meld/wide layouts, SVG output, visibility filtering.

### Session 3 — 3c

- Add `mdex` direct dependency (already in spec §11).
- `GET /` portfolio index; `Portfolio.read_readme/2`.
- `MDEx` safe defaults, raw HTML disabled/sanitized, size cap.
- Canonical metadata and shareable URLs.
- Tests: index filtering, sanitization, missing/large/binary README.

### Session 4 — 3d

- Reuse the existing browser session + `Membership` roles.
- Owner pin/unpin via POST + redirect (no LiveView needed).
- Full DAG and `broken`/`sandbox` nodes for members only.
- Tests: anonymous/owner/trusted/viewer authorization, CSRF, pin changes
  preview, hidden-node leakage.

### Session 5 — close

- Defer review/promotion UI to Phase 4.
- Update spec §13/§16, `docs/README.md`, `docs/progress.md`.
- Run the full suite and `MIX_ENV=prod mix compile --warnings-as-errors`.

## Verification protocol

Every session ends with:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test                       # server tests need Postgres on 55432
MIX_ENV=prod mix compile --warnings-as-errors
```

Then update `docs/progress.md` and commit one conventional commit per session
(`feat: Phase 3a — ...`).

## Risks

- No `Project.visibility` column yet; the portfolio index exposes every
  project. Revisit if private projects are needed.
- Public queries must filter to the preview node when the viewer is anonymous;
  template hiding is not sufficient.
- HEEx dead views need `phoenix_live_view` for `Phoenix.Component`, but no JS
  bundle. Any real interactivity is a separate, spec-updated decision.
- The Ash policy authorizer remains deferred; use controller-level checks.
- Server tests require `CAD_TEST_DATABASE_URL` (default Postgres on 55432).
