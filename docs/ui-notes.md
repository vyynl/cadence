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
- **6c action logs:** the run page renders captured logs as escaped text in a
  `<pre>` (ANSI/control sequences stripped). A "download raw log" or "copy"
  affordance is still missing; add it only if needed, keeping the same escaping
  rules for any inline render.
- **Header nav spacing:** `site-header nav` is inline flow with single-space
  gaps, so `Cadence Portfolio <email> Sign out` reads as one run of text,
  especially at 390px. A `·` separator or grouping the account cluster would
  read better, but any added gap must not overflow the narrow width.
- **Run detail is still unexercised in the demo:** the seed creates no
  `action_runs`, so `/p/cadence-demo/runs` only shows the empty state. The
  `RunLive.Show` layout (status/live refresh, escaped log `<pre>`, artifact
  list) remains covered by markup tests; seed a run or a demo action manifest
  to include it in the visual pass.

## Done

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
