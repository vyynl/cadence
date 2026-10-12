# Cadence — Progress

## Current Phase
Phase 1b — Shared schemas + GitStore (GitStore complete)

## Done
- [x] Read spec + AGENTS.md; audited and resolved all scaffold blockers.
- [x] Spec revisions: LLM client = `axiom_ai` (DeepSeek); graph model =
      `libgraph`; `Hammer` lives in `cadence_shared`; `GitStore` shared-only;
      config model = env vars / `.env` (TOML dropped); §11 dependency table
      corrected.
- [x] Scaffolded umbrella: root `mix.exs`, `.formatter.exs`, `config/config.exs`,
      and the three apps (`cadence_shared`, `cadence_daemon`, `cadence_server`)
      with placeholder modules. Server has only `cadence_shared` (Phoenix deferred
      to Phase 2b).
- [x] `Cadence.Shared.GitStore` — fully absorbed the `gitex` object-store logic
      into a DAG-specialized, ref-less, native module. Implements Git's public
      object format (blob/tree/commit, SHA-1, zlib) with standard modes
      (`100644`/`40000`). API: `init/2` (bare/working), `write_blob/read_blob`,
      `write_tree/build_tree/read_tree`, `write_commit/read_commit` (explicit
      parents, no refs), `checkout/3`. One-line attribution to `awetzel/gitex`
      (MIT) retained in the module doc. Pruned: refs, HEAD, tags, packfile/delta
      reading, history/align.
- [x] 17 ExUnit tests for `GitStore`, including canonical-SHA assertions
      (`hello world\n` blob = `3b18e512…`, empty tree = `4b825dc6…`) and a full
      round-trip (build_tree → commit → checkout). All green.
- [x] `mix compile` clean; `mix format` clean.

## Next
- Phase 1b (remaining): `Node`, `Project`, `Membership` Ecto schemas in
  `cadence_shared` (with changesets) and `Sync.Message` protocol structs.

## Blocked
- (none)

## Spec Deltas
- (none)

## Last Updated
2026-10-12 — GitStore absorbed + DAG-specialized + tested
