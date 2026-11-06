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

- `:CadUnion` — `<C-s>` blocks Neovim while the synchronous union request runs
  (a conflicted meld can wait on the model). The picker notifies "requesting
  meld…" first and reports the token/URL on success, but the UI is frozen
  until the daemon answers. Consider an async submit (job/notification) if
  that becomes annoying.
- `/p/:slug/reviews` — the open-incident panel reuses `.file-tree`/`.file-row`
  and `.flag-badge`, so a **critical** incident looks the same as a `high` one
  and as a proposal status badge. Give severity its own treatment (color,
  icon, or label) in the styling pass.
- `/p/:slug/reviews` — the panel renders *below* the proposal list. With a long
  review queue the incidents (the things that block approval) are below the
  fold; consider moving the panel above the list or adding an open count next
  to the "Open incidents" heading.
- `/p/:slug/reviews` — details render as one dense line
  (`patterns: … · reason: …`) and a long reason is silently cut at 60 chars.
  Decide whether to wrap, tooltip, or show "more".
- `/p/:slug/reviews` — Resolve and Acknowledge share the `.admin-button` style
  and the D8/D9 explanation is a trailing note, not next to the control. A
  destructive/irreversible-looking "Acknowledge" may need different copy
  placement.

## Done

- (none yet)
