# Phase 3 roadmap — Web UI & Portfolio

> Status: **Phase 3 complete (2026-10-24); 3e deferred to Phase 4**. This is the
> session-by-session plan for Phase 3. `docs/spec.md` §7/§13/§16 are canonical;
> this file tracks execution order and acceptance. The cold-start build brief is
> `docs/phase-3b-prep.md`.

## Decisions

| # | Decision | Resolution |
|---|---|---|
| 1 | Public DAG visibility | Full read-only DAG public; any node's repo snapshot browsable |
| 2 | Web DAG Y-axis | Topological depth with fixed spacing; timestamps in hover metadata |
| 3 | 3a view technology | Dead views (done) |
| 4 | 3b technology | Phoenix LiveView project home |
| 5 | Routing | `/p/:slug`, `/p/:slug/n/:id/tree/*path`, `/p/:slug/n/:id/blob/*path` |
| 6 | Repo pane | GitHub-style file tree, file viewer, README underneath |
| 7 | Hover behavior | Tooltip with commit message + node status; highlight only |
| 8 | Intro animation | Root→default lineage along real edge paths, pulse, then reveal repo pane |
| 9 | Secret handling | Mandatory server-side filtering/redaction; quarantine node snapshots on high-confidence findings |
| 10 | Docs source | README only in Phase 3; `docs_schema` in Phase 5 |
| 11 | Project discoverability | All projects public by default; `visibility` column deferred |
| 12 | Review/promotion UI | Deferred to Phase 4 |

## Session plan

| Session | Slice | Deliverable | Exit criteria |
|---|---|---|---|
| 0 | Decisions + docs | Spec updates, roadmap, docs commit | **Done** |
| 1 | 3a | Public project page, `Portfolio`, `GitStore.read_path`, HTML shell | **Done** |
| 2 | 3b-1 | **Done** — LiveView project home, DAG SVG, node routes, message redaction, intro animation | Full DAG/interaction works; tests green |
| 3 | 3b-2 | **Done** — file tree, file viewer, README/MDEx, public secret filter + quarantine | Repo pane browsable; no secret bytes in public HTML |
| 4 | 3c | **Done** — portfolio index, canonical metadata, public-page polish | `/` lists projects; edge cases covered |
| 5 | 3d | **Done** — owner pin/unpin, members read view, explicit unfiltered reveal | Owner controls work; public stays filtered |
| 6 | Close | **Done** — final spec/progress update, full suite + prod compile | Handoff clean |

### Session 2 — 3b-1: LiveView foundation + DAG + intro (done)

Implemented: `/live` socket, prebuilt Phoenix/LiveView bundles served from
dependency priv dirs, `app.js`, `ProjectLive`, `/p/:slug` and
`/p/:slug/n/:node_id`, `DAGLayout`, SVG DAG, CSS intro/hover, and public
commit-message redaction. `lazy_html` is test-only.

Original slice scope (implemented):

- Add `/live` socket to the endpoint using the existing session options; serve
  prebuilt `phoenix.min.js` and `phoenix_live_view.min.js` from dependency priv
  directories via `Plug.Static`; add a small `app.js` LiveSocket bootstrap and a
  CSRF meta tag. No `esbuild`.
- Add `Cadence.ServerWeb.ProjectLive`; wire `live_session` with
  `AshAuthentication.Phoenix.LiveSession` so `current_user` is available without
  forcing auth.
- Replace the static project controller route with live routes for the project
  home and nested node URLs; `handle_params` resolves `:slug`, `:node_id`, and
  `:path`.
- Add `Cadence.ServerWeb.DAGLayout` (pure): depths, layer order, coordinates,
  elbow path data, intro lineage/delays, default node.
- Add `Cadence.ServerWeb.Components.DAG` SVG component: flag colors, pinned ring,
  child-flag edges, accessible node links, tooltip markup.
- Add CSS: 25/75 layout, hover tooltip/highlight, lineage draw animation,
  default-node pulse, right-pane reveal, reduced-motion fallback.
- Right pane in this slice: node header + metadata placeholder. Repository
  content lands in 3b-2.
- Tests: pure layout (linear/branch/meld/wide/lineage), LiveView mount and node
  selection, route/URL patching, public visibility, animation attributes.

### Session 3 — 3b-2: repository browser + README + secret filter (done)

Implemented: `GitStore.list_path/4` + `walk_blobs/3`, `Portfolio` snapshot reads, `MDEx` README rendering, tree/file components, nested tree/blob routes, redaction, and node quarantine. The repo pane is browsable and the public HTML never contains detected secret values.

Original slice scope (implemented):

- Add `Cadence.Shared.GitStore.list_path/4` (directory listing from a commit
  tree, safe paths, sorted dirs-first) and tests.
- Add `Cadence.Server.Portfolio` snapshot reads: tree entries, file content,
  README resolution, binary/size/entry caps.
- Add `MDEx` dependency (already in spec §11); render README with raw HTML
  disabled and explicit missing/large states.
- Add `Cadence.Server.PublicContent` (or similarly named) secret filter:
  - sensitive-path hiding,
  - text pattern detection + `[REDACTED]`,
  - private-key block blocking,
  - **node-level quarantine** when any high-confidence secret is found in the
    snapshot (hide the whole repo pane; keep the DAG node),
  - commit-message redaction,
  - binary content suppression,
  - no content logging.
- Apply the filter on initial mount **and every LiveView event**; never send raw
  secret bytes to an anonymous client.
- Add file tree, breadcrumbs, file viewer, README below the tree; nested URLs.
- Add `CAD_FILE_MAX_BYTES`, `CAD_README_MAX_BYTES`, `CAD_TREE_MAX_ENTRIES`,
  `CAD_DAG_INTRO_MS` config + `.env.example`.
- Tests: tree navigation, file view, README, binary/oversize/missing,
  path-traversal rejection, secret redaction/hiding, public-event bypass
  attempts, no secret bytes in rendered HTML.

### Session 4 — 3c: portfolio index + polish (done)

Implemented: `/` lists projects newest first with node counts, canonical/OG
metadata for the index and project/tree URLs, skip link, focus styles, and
responsive project cards.

Original slice scope (implemented):

- Turn `/` into the project index.
- Canonical metadata/shareable URLs.
- Public empty/error states.
- Remaining accessibility/responsive polish.

### Session 5 — 3d: authenticated controls (done)

Implemented: `ProjectAdmin.set_pinned/3`, owner-only pin/unpin in the LiveView,
owner/trusted member read panel, and an explicit raw-view toggle for
owner/trusted members. Viewer/anonymous events are rejected server-side; raw
view resets on node change.

Original slice scope (implemented):

- Reuse `current_user` + `Membership` roles.
- Owner pin/unpin; membership read views.
- Explicit “reveal unfiltered” action for owner/trusted; public and default
  authenticated renders stay filtered.
- Tests: anonymous/owner/trusted/viewer authorization, CSRF, pin changes
  preview, filtered-vs-raw behavior.

### Session 6 — close (done)

Completed: 3e review/promotion UI deferred to Phase 4; spec §13/§16, docs
index, and progress updated; full suite and prod compile verified. Phase 4
planning starts from `docs/phase-4-prep.md`.

## Verification protocol

Every session ends with:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test                       # server tests need Postgres on 55432
MIX_ENV=prod mix compile --warnings-as-errors
```

Then update `docs/progress.md` and commit one conventional commit per session
(`feat: Phase 3b-1 — ...`).

## Risks

- **Secret filtering is best-effort**, not a guarantee. Regex/high-confidence
  patterns can miss obfuscated or unknown credentials. Owners must rotate any
  secret that was committed; the filter reduces accidental public exposure.
- Full public DAG exposes `broken`/`sandbox` nodes and their snapshots. Recorded
  as an open decision in spec §16.
- Public queries must apply filtering server-side on every event, not just the
  initial render; LiveView events are an attack surface for bypass attempts.
- No `Project.visibility` column yet; the portfolio index exposes every project.
- Syntax highlighting is undecided; a client-side highlighter must not receive
  unfiltered content.
- The Ash policy authorizer remains deferred; use server-side checks in the
  LiveView/context.
- Server tests require `CAD_TEST_DATABASE_URL` (default Postgres on 55432).
