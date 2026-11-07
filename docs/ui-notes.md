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

- **6c action logs:** captured logs are TTY output and may contain ANSI/terminal
  escape sequences. Render them escaped in a `<pre>` (never `raw/1`) and add a
  "download" or "copy" affordance only after the escape handling is in place.

## Done

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
