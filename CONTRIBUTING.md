# Contributing to Cadence

Cadence is a local-first, self-hosted source control system built around a DAG
of snapshots rather than Git branches. The umbrella contains three Elixir
apps — `cadence_shared`, `cadence_daemon`, and `cadence_server` — plus the
`cadence.nvim` Neovim plugin.

Read these first, in order:

1. `docs/spec.md` — the canonical contract. If a design question is not
   answered there, resolve it in the spec (or add a §16 entry) before
   implementing.
2. `docs/README.md` — the documentation index and operator guides.
3. `docs/release-notes.md` — current release, upgrade notes, and known
   limitations.

## Prerequisites

- Elixir `~> 1.20` and OTP 29 — the versions CI and `docker/Dockerfile` use.
- Docker, for the PostgreSQL test database and the demo stack.
- Neovim 0.9+ and `luac` (or `luajit`) only if you work on the plugin; the
  daemon and server do not need it.
- On Linux, `inotifywait` from `inotify-tools` for the default watcher backend,
  or set `CAD_WATCH_BACKEND=fs_poll`.

## Setup

Fetch dependencies from the umbrella root:

```bash
mix deps.get
```

Server tests need PostgreSQL on `localhost:55432`, matching `config/test.exs` and
the CI service:

```bash
docker run --rm -d --name cadence-test-pg \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=cadence_test \
  -p 55432:5432 postgres:16-alpine
```

Configuration is environment-only: every setting is a `CAD_*` variable read in
`config/runtime.exs`, with a documented default (spec §12.6). Do not hardcode a
configurable value in code, and do not commit secrets — tokens belong in
`~/.config/cadence/env` (chmod 600) or a git-ignored `.env` file.

For a browsable stack, `docker compose up --build` starts PostgreSQL plus a seeded
dev server on <http://localhost:4000> (`docs/demo.md`). Operator setup is in
`docs/deploy.md`; local daemon setup is in `docs/daemon-setup.md`.

## The merge gate

Run these from the umbrella root. They are the project's merge gate and the
commands CI runs:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=prod mix compile --warnings-as-errors
mix test
mix test --cover
```

`mix test --cover` must exit 0. The floor is **80% per app**
(`test_coverage: [summary: [threshold: 80]]` in each app's `mix.exs` and at the
umbrella root). Mix exits `3` for a coverage miss and `2` for a test failure.

Before opening a pull request, also run the repository checks CI runs:

```bash
mix hex.audit
mix deps.unlock --check-unused
(cd apps/cadence_server && mix sobelow --exit medium)
mix deps.audit --ignore-file .mix_audit.ignore
```

`credo` and `dialyzer` are **not** configured in this umbrella — do not report
them as run.

Use the focused loop while iterating; the umbrella accepts an app-local test
path:

```bash
mix test apps/cadence_server/test/proposals_test.exs
```

### Formatting

Run `mix format` before you finish. `mix format --check-formatted` is the
authority — the `mix` formatter can rewrite files after an edit, so re-check
rather than assuming an edit was formatted.

### Docs changes

- Use one H1 per file and sentence-case headings; write instructions in the
  imperative and describe shipped behavior in the present tense.
- Link other documents with relative Markdown links, not code spans. Do not link
  local-only files that are not tracked in the repository.
- Define an acronym on first use, and use the project terms: **node** (a
  session snapshot), **snapshot** (a node's tree), **commit** (the Git object),
  **Git** in prose, `git` only in commands.
- Update `docs/spec.md` for behavior changes and `docs/release-notes.md` for
  user-visible changes. Configuration belongs in spec §12.6 and
  `.env.example`.
- Run a relative-link and anchor check before opening the pull request; broken
  cross-references are review blockers.

### Plugin checks

When `cadence.nvim` changes, syntax-check every Lua file and run the headless
specs:

```bash
find cadence.nvim -name '*.lua' -exec luac -p {} +
nvim --headless -l cadence.nvim/spec/graph_spec.lua
nvim --headless -l cadence.nvim/spec/diff_spec.lua
nvim --headless -l cadence.nvim/spec/doc_spec.lua
nvim --headless -l cadence.nvim/spec/proposal_spec.lua
nvim --headless -l cadence.nvim/spec/client_spec.lua
```

## Test conventions

- Every public function in `cadence_shared` gets a test.
- `Cadence.Shared.GitStore` keeps a round-trip integration test (init → blob →
  tree → commit → read) on a temp directory.
- Daemon sync tests use `Req.Test` through `TestSyncServer`; no live HTTP.
- Server tests use `Phoenix.ConnTest` for controllers and
  `Phoenix.LiveViewTest` for LiveViews.
- No test calls a real LLM. Inject `TestMeldLLM` / `TestDocsLLM` through
  `:meld_llm` / `:docs_llm`, and `FakeDocker` for the Docker API. **Do not add
  Mox** — injected fakes are the project convention.
- Tests must not depend on arbitrary sleeps; use barriers, queue drains, or
  explicit synchronization.

## Hard rules

These are enforced in review:

- Never shell out to `git`; use `Cadence.Shared.GitStore` for object
  operations.
- Never run `mix phx.new`; the server app is created manually.
- Do not add a dependency outside spec §11. Update the technology table first
  and get approval.
- Every configurable value is a `CAD_*` env var read in `config/runtime.exs`
  (spec §12.6).
- Do not duplicate code between daemon and server. Shared behavior belongs in
  `cadence_shared`.
- Never auto-promote a meld to `functioning`; validation is required (spec
  §3.1).
- Follow the build order in spec §13; do not skip ahead.
- Never commit secrets.
- Never mount the raw Docker socket in a publicly reachable deployment; use the
  socket proxy (spec §8.4).
- Renames are umbrella-wide: module names, env prefixes, and command prefixes
  are load-bearing.

Respect the app boundaries: `cadence_shared` must not depend on Phoenix,
PostgreSQL, Bandit, or any web stack, and `cadence_daemon` must not depend on
Phoenix, PostgreSQL, or LiveView.

## Workflow

- Work on a branch, not on `master`.
- Plan before building. For anything larger than a single-file mechanical edit,
  describe the files, approach, and tradeoffs in an issue or draft pull request
  and wait for a decision. Plan-then-build is the project convention; do not
  interpret silence as approval.
- Keep one deliverable per change and keep commits focused. Use an imperative
  subject line and explain the *why* in the body.
- Update `docs/spec.md` when behavior changes, and record unresolved questions
  in spec §16. Update `docs/release-notes.md` for user-visible changes.
- Changes that touch auth, sessions, tokens, or the sync protocol get a closer
  review; describe the security impact in the pull request.
- If you touch a public function, add or update its test in the same change.

## Pull requests

Use `.github/PULL_REQUEST_TEMPLATE.md`. A pull request should state what
changed and why, link an issue when one exists, list the affected apps, and
show the exact commands you ran (format, dev/prod compile, tests, coverage).

The checklist in the template mirrors the merge gate above. "Done" is not "it
compiles": formatting, dev and prod compile, tests, the coverage floor, and the
no-hardcoded-config rule all have to pass. CI runs the same gate; describe what
you ran locally rather than assuming a green run.

## Reporting bugs and requesting features

- **Bugs:** use the bug report issue form. Include the component, version, OS
  and runtime, reproduction steps, expected versus actual behavior, and logs
  with secrets redacted.
- **Features:** use the feature request form. Describe the problem before the
  proposal, list alternatives, and note any spec section or §11 dependency the
  change would affect.
- **Security:** do not open a public issue. Follow `SECURITY.md`.
