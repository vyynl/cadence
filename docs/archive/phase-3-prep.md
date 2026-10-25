# Phase 3 prep — Web UI & Portfolio

> Status: **planning / ready to slice**. Phase 2b is complete. This is the
> cold-start brief for Phase 3; `docs/spec.md` §7 and §13 remain canonical.
> Pick one slice, confirm its acceptance, then implement.

## 1. Goal

Turn the synced DAG into a readable web product:

- public project landing pages and DAG visualization,
- markdown-rendered project docs/README,
- authenticated owner/trusted controls (visibility, pinning, later review).

Phase 3 is **read-mostly**. Union execution, doc automation, and Docker actions
belong to later phases; their UI must not be built ahead of their backends.

## 2. Current state (verified)

- Server has Phoenix endpoint/router, Postgres schemas for `Project`, `Node`,
  `Membership`, OAuth/API-key auth, sync endpoints, `ProjectGit`, PubSub, and
  the notification socket.
- There are **no web/UI routes, controllers, templates, components, or asset
  files yet**. The browser pipeline only serves auth/token forms.
- `Cadence.Shared.DAG` already exposes `graph/1`, `depths/1`, `edges/1`,
  `preview_node/1`, and `default_node/2`.
- `Cadence.Shared.GitStore` can read commits/trees/blobs; `ProjectGit.open/1`
  opens a project's server-side bare store.
- `Phoenix.LiveView`, `Phoenix.HTML`, and `Phoenix.Template` are present
  transitively through `ash_authentication_phoenix`, but are not direct server
  dependencies and there is no asset build pipeline.
- Daemon and sync are complete; Phase 3 should not require daemon changes.

## 3. Dependency and wiring gaps

Likely 3a changes:

- Declare direct deps in `cadence_server/mix.exs`:
  - `{:phoenix_live_view, "~> 1.2"}`
  - `{:phoenix_html, "~> 4.3"}`
  - `{:mdex, "~> 0.14"}`
- Add `phoenix_live_view`/HTML helpers to `Cadence.ServerWeb` (`html_helpers`,
  `live_view`), plus a layout/component root.
- Add browser routes and an HTML error path; keep `/sync/*` JSON-only.
- Decide the asset strategy before the first LiveView slice:
  - **3a dead views** (controller + HEEx, server-rendered SVG) need no JS build;
  - **LiveView** interactivity needs a minimal JS asset pipeline
    (`esbuild` or a hand-served `app.js`). Avoid Tailwind unless the UI needs it.
- Update spec §11 only if a genuinely new dependency is added (`esbuild` would
  be new; `phoenix_live_view`, `phoenix_html`, and `MDEx` are already named).

No new env vars are expected for 3a. `CAD_PUBLIC_URL` already exists.

## 4. Data/query layer

Add a server context (working name `Cadence.Server.Portfolio`) rather than
putting Ecto queries in controllers:

- `get_project_by_slug/1`
- `list_nodes/1` (deterministic ordering)
- `preview_node/1` (delegate to `Cadence.Shared.DAG.preview_node/1`)
- `read_file/3` or `read_readme/2` for a node's tree
- `membership_for/2` for role-aware views

For file rendering, prefer a small shared `GitStore` helper that reads a path
from a commit (commit → root tree → entry → blob) over checking out to a temp
directory. Add tests for missing files, directories, binary blobs, and size
caps.

Public visibility must be resolved before queries are exposed: see the open
decision in spec §16.

## 5. Proposed slices

### 3a — UI foundation + read-only project page

- Direct web deps, layout, browser routes, HTML error pages.
- `Cadence.Server.Portfolio` read queries and project-by-slug lookup.
- Public project page showing name/slug and the preview node.
- Release: real HTML for a seeded project, no JS required.

### 3b — DAG renderer

- Server-side layout data: depths, layer order, edges, coordinates.
- SVG HEEx component with flag colors, pinned ring, elbow edges, wrap/break
  marker, and accessible titles.
- Hover/selection behavior. If this needs LiveView, introduce the JS pipeline
  here rather than in 3a.
- Resolve the Y-axis contradiction in spec §16 before implementing.

### 3c — Public portfolio and Markdown

- Project index/portfolio page.
- README/docs rendering with `MDEx`, safe HTML defaults, size limits, and a
  clear “no README” state.
- Shareable URLs and canonical metadata.

### 3d — Authenticated owner/trusted views

- Use the existing AshAuthentication session + project role checks.
- Pin/unpin preview nodes (owner-only per §4.5).
- Show broken/sandbox nodes to authorized users only.
- Membership read views; full management can follow if needed.

### 3e — Review/promotion UI (phase-boundary item)

Spec §7.2 lists proposal review/approval, but the proposal/meld backend is
Phase 4. Do not build an approval UI before Phase 4. Either:
- defer this slice into Phase 4, or
- ship a read-only “coming after unions” placeholder.

Actions panels, Livebook embedding, and doc-diff review similarly depend on
Phase 5/6 and stay out of Phase 3.

## 6. Decisions / open questions

Need sign-off before the affected slice:

1. **Public DAG visibility.** §4.5 says public visitors see the preview node
   only; §7.1 says the public DAG is read-only. Choose:
   - preview-only public view, or
   - full DAG read-only for everyone.
   Recorded in spec §16.
2. **Y-axis.** §7.3 specifies time-clamped Y; the Neovim picker and layered
   layout use depth. Choose time-based, depth-based, or a hybrid. Recorded in
   spec §16.
3. **3a view technology.** Dead view first (fast, no JS) vs LiveView from day
   one (needs an asset build). Recommendation: dead view for 3a, LiveView in 3b.
4. **Routing.** `/p/:slug` vs `/:slug`; reserve `/auth`, `/sync`, `/health`,
   and static paths. Recommendation: `/p/:slug` plus `/` portfolio.
5. **Docs source.** README only for 3c, or the §9 `docs_schema` structure too.
   Recommendation: README first; structured docs in Phase 5.
6. **Public access control.** Anonymous by default (§7.4) or signed URLs later.
   Keep the §16 deferred decision; do not block 3a.

## 7. Security notes

- Treat node content and Markdown as untrusted; do not enable raw HTML unless
  sanitized. Cap file/README size before rendering.
- Public pages must not expose non-preview nodes if decision 1 is preview-only.
- Owner/trusted checks must be server-side; hiding controls in HTML is not
  authorization.
- Keep API-key sync routes on their JSON pipeline; browser sessions must not
  grant sync-token access implicitly.
- Do not log project content or tokens.

## 8. Tests / verification

- `Phoenix.ConnTest` for public routes, 404s, and visibility.
- `Phoenix.LiveViewTest` for any LiveView slices.
- Pure tests for layout/coordinate data and SVG component output.
- `MDEx` tests for sanitization, missing README, binary/large files.
- Auth/role tests for pinning and broken/sandbox visibility.
- Full suite:
  ```bash
  mix format --check-formatted
  mix compile --warnings-as-errors
  MIX_ENV=prod mix compile --warnings-as-errors
  mix test
  # server tests need Postgres on 55432
  ```

## 9. Out of scope

- Union/meld execution, proposals, approvals (Phase 4).
- Doc schema parsing and automated doc agents (Phase 5).
- Docker actions and streaming output (Phase 6).
- Storage repack/object negotiation (Phase 7).
- Any daemon changes unless a concrete read-path gap requires one.
