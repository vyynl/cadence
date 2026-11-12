## Summary

<!-- What changed, and why. One or two paragraphs. -->

## Linked issue

<!-- Closes #123, or "none". -->

## Affected app(s)

- [ ] `cadence_shared`
- [ ] `cadence_daemon`
- [ ] `cadence_server`
- [ ] `cadence.nvim`
- [ ] Docs / spec
- [ ] CI / packaging / compose

## What changed

<!-- Key decisions, tradeoffs, and anything a reviewer should look at first. -->

## Tests run

<!-- Check what you actually ran locally and paste the result line. -->

- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `MIX_ENV=prod mix compile --warnings-as-errors`
- [ ] `mix test`
- [ ] `mix test --cover` (80% floor per app)
- [ ] Plugin checks (`luac -p`, `nvim --headless -l spec/*_spec.lua`) — only if `cadence.nvim` changed

<!-- If you skipped a step, say why. -->

## Spec / docs updated

- [ ] `docs/spec.md` (section: )
- [ ] `docs/release-notes.md`
- [ ] `docs/progress.md` (session handoff)
- [ ] Not needed — no behavior or configuration change

## Checklist (`AGENTS.md` §11)

- [ ] Code is formatted (`mix format --check-formatted` passes).
- [ ] Dev and prod compile clean (`mix compile --warnings-as-errors`, `MIX_ENV=prod mix compile --warnings-as-errors`).
- [ ] Relevant tests pass (`mix test`; server tests used the Postgres container on port 55432).
- [ ] New public functions have tests.
- [ ] Coverage floor holds (`mix test --cover` exits 0).
- [ ] No hardcoded configuration values were introduced (`CAD_*` env vars, spec §12.6).
- [ ] No dependency was added outside spec §11 — or the spec table was updated with approval.
- [ ] The change aligns with the relevant spec section, or the spec was updated.
- [ ] No secrets, tokens, or personal data are included in the diff or this description.
- [ ] If this touches auth, sessions, tokens, or the sync protocol, the security impact is described above.

## Notes for reviewers

<!-- Optional: follow-ups, known limitations, screenshots for UI changes. -->
