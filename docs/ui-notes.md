# UI notes & tuning backlog

Drop notes here between sessions — anything visual, layout, copy, or "this
feels wrong". The next session reads this before touching UI work, and a
styling pass is planned after 4c-3 (incident panel) unless a demo is imminent.

## How to use

- One bullet per observation.
- Say **where** (URL/route), **what you see**, and **what you expected**.
- Screenshots: put them in `docs/images/` and link from the bullet.
- No need to be polished; this is a scratchpad, not a spec.

## Open

- **`/favicon.ico` returns 404 (2026-11-11, audit smoke).** Every first page
  load logs one `404 Not Found` in the console (the browser's automatic
  favicon request); the server log shows `no route found for GET /favicon.ico`.
  Expected: either a real favicon route or a `<link rel="icon">` pointing at an
  inline SVG, so the public pages are console-clean. No visual impact today.
- **Right-edge project metadata rail (GitHub-style; future idea, user-suggested
  2026-11-08).** Consider a narrow column on the right of the repository pane on
  `/p/:slug`, with GitHub-About-style blocks. Map it to Cadence concepts rather
  than copying GitHub:
  - **About** — project description, README/license links, and recent activity
    (nodes/commits in the last N days). A description has no writer today; add
    one only with an owner/trusted control.
  - **Members** — the existing owner/trusted/approver/viewer memberships
    instead of "contributors"; an avatar/name list must not leak emails to
    viewers (§7.2).
  - **Pinned / Proposals / Incidents** — pinned nodes and open proposal /
    incident counts are the useful equivalents of Releases/Issues. "Releases"
    and "Packages" have no model yet; reserve or omit those slots.
  - **Languages** — derive from the selected snapshot's file extensions if the
    existing capped tree walk can do it cheaply; otherwise defer. Do not add an
    expensive scan to every project mount.
  Layout/contract: the project home is the 25/75 DAG + repository grid (§7.3);
  a third column changes that rule and must stack cleanly at 390px
  (DAG → repository → rail) without horizontal overflow. Load counts with
  `assign_async` (no DB query in the disconnected mount), keep every count
  bounded/capped, and refresh only via the existing project events. Treat this
  as a design idea: decide the column, data sources, and the §7.3 update before
  building.

## Done

- **DAG hover card layering (2026-11-11):** the node card was rendered inside
  each node's link, so a later node's dot painted over a card that extended
  below/right of the hovered node (the top layers were unreadable). The SVG now
  paints edges and non-interactive node graphics first, then a final interaction
  layer with one focusable link per node (transparent hit circle + card), so a
  card is always above the graphics. The hover scale was replaced by an accent
  ring on the hit circle (the dot is no longer a descendant of the link), and
  the SVG's "Project session graph" `<title>` was replaced with an `aria-label`
  so the browser no longer shows a native tooltip on every hover. Verified
  headlessly: hovering the top node at 1440×1000 shows the card with
  `elementFromPoint` resolving to the card body. Spec §7.3 records the layer
  rule; `dag_component_test.exs` pins the order and the label.
- **Raw log download (2026-11-11, closeout slice 2):** the run page's Output
  section links **Download raw log** (`/p/:slug/runs/:run_id/log`). The
  controller is member-only (`Runs.get/3` re-checks), reads the recorded
  `log_path` through `Runs.log/1`, and answers `text/plain` + `attachment` +
  `private, no-store`; every refusal is a 404.
- **Header nav spacing (2026-11-11, closeout slice 2):** the account cluster is
  grouped in `.nav-account`; `.site-header nav` is a wrapping flex row with a
  gap, and `.nav-user` truncates. "Cadence Portfolio email Sign out" reads and
  wraps cleanly at 390px with no overflow.
- **Seeded demo run (2026-11-11, closeout slice 2):** `cadence-demo` seeds one
  finished (`:succeeded`) action run on the pinned node with a captured
  `output.log`, so the run history and detail pages are part of the tour;
  `--reset` removes the rows and their artifact dirs.
- **DAG canvas width (2026-11-08, user-flagged):** fixed. `DAGLayout.layout/2`
  now sizes the SVG from the columns the graph actually occupies (capped by
  `max_columns`), so the default no longer reserves 10 columns (444px) for a
  2-column graph. `.dag-canvas` gained `min-width: 100%`: a small graph fills
  the rail's scroll box without a horizontal scrollbar, while a graph wider
  than the rail still scrolls at natural size. Nodes stay left-aligned and
  unscaled per §7.3, so the tooltip and selection coordinates are unchanged.
  Verified at 1440×1000 and 390×844 with `scrollWidth == clientWidth` and
  `overflowing == false`; before/after screenshots under
  `docs/images/dag-width-{overflow,fixed}-*-20261108.png` (the before shot
  forces a classic scrollbar so headless Chrome paints it).
- **Proposal queue kind column (2026-11-08):** the fixed `2.4rem` `.file-kind`
  width let `PROMOTION` overflow into the proposal title (`PROMOTIONPromotion
  proposal`). It is now `min-width: 2.4rem` + `white-space: nowrap`, so short
  labels keep the column and longer kinds expand; verified in the review hub at
  wide/narrow, light/dark.
- **Wide/narrow + light/dark pass (2026-11-08):** `/`, `/p/cadence-demo`, both
  review hubs (`cadence-demo`, `meld-review`), `/p/cadence-demo/runs` (empty
  state), and a pending public proposal page were rendered at 1440×1000 and
  390×844 with `prefers-color-scheme: light` and `dark`. No horizontal
  overflow, dark tokens applied (`#0d1117`/`#e6edf3`), incident severity,
  status, docs, and file-status badges stayed readable, and no console/page
  errors were reported. The seeded `union-smoke` project from the retained
  Postgres volume also appeared; that is demo data, not a layout issue.
- `:CadUnion` no longer blocks Neovim — 4d-3 submits asynchronously and reports
  the proposal token/URL as a notification.
- `/p/:slug/reviews` severity has its own treatment: a `critical` badge with a
  marker, a `high` badge, and a left accent on the incident row. The severity
  word stays visible, so the state is not conveyed by color alone.
- `/p/:slug/reviews` incidents now render **above** the proposal queue with an
  open count and a critical-count line.
- Incident details render as a wrapped `<dl>` (patterns, sensitive paths, full
  reason) instead of one truncated line.
- Resolve and Acknowledge are distinguishable (`button-primary` vs
  `button-warning`) with a one-line hint next to each control; the trailing
  paragraph is gone.
