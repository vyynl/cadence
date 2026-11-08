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
