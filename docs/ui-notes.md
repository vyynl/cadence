# UI backlog

An internal list of visual, layout, copy, and interaction issues found in the
browser. It is a working backlog, not a specification; user-facing behavior
belongs in [`spec.md`](spec.md), and shipped changes belong in
[`release-notes.md`](release-notes.md).

## How to use this list

- One bullet per observation.
- Say **where** (URL or route), **what you see**, and **what you expected**.
- Screenshots go in `docs/images/` and are linked from the bullet.
- Keep resolved items in **Recently fixed** only until the next release note
  covers them.

## Open

- **Right-edge project metadata rail (future idea).** Consider a narrow column
  on the right of the repository pane on `/p/:slug`, with GitHub-About-style
  blocks mapped to Cadence concepts rather than copied from GitHub:
  - **About** — project description, README and license links, and recent
    activity (nodes or commits in the last N days). A description has no writer
    today; add one only with an owner/trusted control.
  - **Members** — the existing owner, trusted, approver, and viewer memberships
    instead of "contributors"; an avatar or name list must not leak emails to
    viewers ([spec §7.2](spec.md#72-ownertrusted-views-authenticated)).
  - **Pinned / Proposals / Incidents** — pinned nodes and open proposal and
    incident counts are the useful equivalents of Releases and Issues.
    "Releases" and "Packages" have no model yet; reserve or omit those slots.
  - **Languages** — derive from the selected snapshot's file extensions if the
    existing capped tree walk can do it cheaply; otherwise defer. Do not add an
    expensive scan to every project mount.
  - Layout and contract: the project home is the 25/75 DAG and repository grid
    ([spec §7.3](spec.md#73-dag-visualization-spec)); a third column changes
    that rule and must stack cleanly at 390px (DAG, repository, rail) without
    horizontal overflow. Load counts with `assign_async` (no database query in
    the disconnected mount), keep every count bounded, and refresh only through
    the existing project events. Treat this as a design idea: decide the column,
    data sources, and the §7.3 update before building.

## Recently fixed

- **UI links are buttons.** Standalone UI links (header account links, project
  Reviews/Runs, Run history, Browse the full history, “Back to…”, incident and
  result actions, account actions) are compact outline buttons with an
  accent-tinted hover/focus fill. Inline README/proposal prose links and list
  rows keep their normal link treatment so reading flow is not broken.
- **White navigation flash.** The `html` canvas was left at the browser's white
  default (only `body` had a background). The root layout now paints the
  light/dark canvas inline before the stylesheet, and `app.css` also sets
  `html` + `body` backgrounds, so full-page links no longer flash white.
- **Redundant header link.** The bare `Portfolio` link is gone; the Cadence
  brand already links to `/`, leaving the header as brand + account cluster.
- **Favicon and brand mark.** The header and auth pages use the simple DAG-fork
  mark (`Components.Brand`), the root layout links `/assets/favicon.svg`, and
  `/favicon.ico` answers with the SVG, so the console is clean.
- **Auth/account surfaces.** Sign-in, the TOTP challenge, first-time enrollment,
  recovery codes, and `/account` share one centered-card layout and the existing
  AA color tokens (light and dark); verified at 1440×1000 and 390×844.

- **DAG hover-card layering.** The SVG now paints edges and non-interactive node
  graphics first, then an interaction layer with one focusable link per node, so
  a hover card is always above the graphics. The hover scale became an accent
  ring, and the SVG uses an `aria-label` instead of a `<title>` so the browser
  does not show a native tooltip on every hover
  ([spec §7.3](spec.md#73-dag-visualization-spec)).
- **Raw log download.** The run page links **Download raw log**
  (`/p/:slug/runs/:run_id/log`), served as `text/plain` with
  `content-disposition: attachment`; every refusal is a 404.
- **Header navigation spacing.** The account cluster is grouped and wraps
  cleanly at 390px without overflow.
- **Seeded demo run.** `cadence-demo` includes one finished action run with a
  captured log, so run history and detail pages are part of the demo tour.
- **DAG canvas width.** The SVG is sized from the columns the graph actually
  occupies, so a small graph no longer reserves a wide rail; a graph wider than
  the rail still scrolls at its natural size. Verified at 1440×1000 and 390×844
  with `scrollWidth == clientWidth`. Before and after:
  [`overflow`](images/dag-width-overflow-1440-20261108.png) and
  [`fixed`](images/dag-width-fixed-1440-20261108.png); mobile:
  [`overflow`](images/dag-width-overflow-390-20261108.png) and
  [`fixed`](images/dag-width-fixed-390-20261108.png).
- **Proposal queue kind column.** A fixed-width `.file-kind` let `PROMOTION`
  overflow into the title; it now uses `min-width` and `nowrap`, so short labels
  keep the column and longer kinds expand.
- **Wide/narrow and light/dark pass.** `/`, `/p/cadence-demo`, both review hubs,
  the runs empty state, and a public proposal page render without horizontal
  overflow at 1440×1000 and 390×844 in both color schemes.
- **Review hub incident presentation.** Incidents render above the proposal
  queue with an open count; severity has its own badge and left accent, details
  render as a wrapped definition list, and Resolve and Acknowledge are visually
  distinct.
- **Non-blocking `:CadUnion`.** The Neovim command submits asynchronously and
  reports the proposal token or URL as a notification instead of blocking.
