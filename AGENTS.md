# Cadence — Agent Working Conventions

> The canonical spec is `docs/spec.md`. **Read it in full** before any task
> that isn't purely mechanical. This file is the *how*; the spec is the *what*.

---

## 1. Project Identity

- **Name:** Cadence
- **What it is:** A local-first, self-hosted source control system built
  around a DAG of session nodes rather than Git branches.
- **Language:** Elixir (OTP), umbrella project.
- **Ignore legacy names:** `superposition`, `Superposition`, `SC_`, `:Sc` are
  obsolete. Use `Cadence`, `Cadence.*`, `CAD_`, `:Cad`.

---

## 2. Session Handoff

**This section is the operational contract for every session. Read it before
doing anything else, and follow it again before ending.**

### At the start of a session

1. Read `docs/progress.md` **before** anything else. If it doesn't exist,
   create it using the template in Appendix A before starting work.
2. In your first response, confirm you've read it and state what you believe
   the current task is.
3. If the "Blocked" section of `docs/progress.md` is non-empty, address the
   block before starting new work — or ask me whether to skip it.

### At the end of a session (or when I say "wrap up")

1. Update `docs/progress.md` following the template in Appendix A:
   - **Done** — what was completed and verified this session.
   - **Next** — the immediate next step, specific enough to start cold.
   - **Blocked** — anything unresolved, with enough context to pick up.
   - **Spec Deltas** — any spec ambiguity discovered this session.
2. If the session revealed a spec contradiction or missing information,
   update `docs/spec.md` directly, or add an entry to spec §16 (Open
   Decisions). Do not leave it undocumented.
3. Run `mix format` and `mix compile` so the tree is clean on exit.
4. **Stop.** Do not start new work after updating `docs/progress.md`. The
   session is over.

### Why this matters

A session that ends without a handoff costs the next session 5–10 turns of
context re-discovery. A session that ends *with* one starts working
immediately. The handoff ritual is not optional overhead — it's what makes
multi-session work possible.

---

## 3. Project Structure

```
cadence/                        (umbrella root)
├── apps/
│   ├── cadence_shared/         schemas, sync protocol, GitStore, LLM client
│   ├── cadence_daemon/         local process: watcher, commit queue, Unix socket
│   └── cadence_server/         Phoenix: sync endpoint (web UI Phase 3, meld worker Phase 4)
├── config/                     umbrella-level config
├── docs/
│   ├── README.md               doc index + read order
│   ├── spec.md                 CANONICAL CONTRACT
│   ├── progress.md             SESSION HANDOFF (see §2)
│   ├── phase-4-prep.md         current phase brief
│   ├── opencode.md             agent tooling: skills, gates, artifacts
│   └── archive/                historical briefs + full Phase 1–3 log
├── scripts/
│   └── setup-opencode.sh       vendor/update the agent skills checkout
├── .opencode/                  agent tooling (skills checkout is git-ignored)
├── opencode.jsonc              formatter + destructive-command guards
├── mix.exs                     umbrella root
├── docker-compose.yml          server deployment (planned, spec §12.4)
└── AGENTS.md                   this file
```

### App boundaries (non-negotiable)

| App | May depend on | Must NOT depend on |
|---|---|---|
| `cadence_shared` | Ecto, `axiom_ai`, `libgraph` | Phoenix, Postgres, Bandit, any web stack |
| `cadence_daemon` | `cadence_shared`, SQLite (`ecto_sqlite3`), `file_system`, `Bandit`, `Plug`, `Hammer` | Phoenix, Postgres, LiveView |
| `cadence_server` | `cadence_shared`, Phoenix, LiveView, Postgres, `ex_docker_api`, `AshAuthentication` | — |

`cadence_shared` is a `path` dependency of both `cadence_daemon` and
`cadence_server`. **Schemas, sync protocol types, `GitStore`, and the LLM
client live ONLY in `cadence_shared`.** Never duplicate them.

Both daemon and server define their own `Repo`:

- `Cadence.Daemon.Repo` → SQLite
- `Cadence.Server.Repo` → Postgres

Both point at schemas defined in `cadence_shared`.

---

## 4. Hard Rules

These are the constraints that agents most commonly violate. They are not
suggestions.

1. **Never shell out to `git`.** Use `Cadence.Shared.GitStore` for all Git
   object operations.
2. **Never run `mix phx.new`.** The server app is created manually.
3. **Never add a dependency** outside spec §11 without first updating the
   spec's technology table and getting approval.
4. **Never hardcode configuration.** Every configurable value is an env var
   prefixed `CAD_`, read in `config/runtime.exs`. See spec §12.6.
5. **Never duplicate code between daemon and server.** If both need it, it
   belongs in `cadence_shared`.
6. **Never auto-promote a meld to `functioning`.** Validation is required.
   See spec §3.1.
7. **Never skip ahead in the build order** (spec §13). Each phase depends on
   the previous one.
8. **Never commit secrets.** Tokens go in `~/.config/cadence/env` (chmod 600)
   or in a `.env` file. Never in `config/`, never in source.
9. **Never mount the raw Docker socket** in a publicly-reachable deployment.
   Use the socket proxy. See spec §8.4.
10. **Never rename things without a find-and-replace across the whole
    umbrella.** Elixir module names, env prefixes, and command prefixes are
    load-bearing.
11. **Never end a session without updating `docs/progress.md`.** See §2.

---

## 5. Working Pattern

**Plan-then-build.** For any task larger than a single-file mechanical edit:

1. Read the relevant spec section(s) and `docs/progress.md`.
2. Propose the change (files affected, approach, tradeoffs).
3. **Wait for approval.**
4. Implement.
5. Run `mix compile` and the relevant tests.
6. Update `docs/progress.md` if the session is ending.

Do not skip step 3. Do not interpret silence as approval. Do not batch
multiple proposals into one response and proceed if only some are approved.

**One deliverable per session.** Do not attempt to complete a full phase in
one session. End when there's a verified deliverable, when the next step is a
different concern, or when context has grown large enough that the agent's
attention is spread thin.

**When in doubt, ask.** A clarifying question costs one turn. A wrong
implementation costs many.

---

## 6. Common Commands

```bash
# Compile everything
mix compile

# Compile a single app
cd apps/cadence_daemon && mix compile

# Run tests for one app
cd apps/cadence_shared && mix test

# Format all code
mix format

# Add a dependency to one app
cd apps/cadence_daemon
# edit mix.exs manually, then:
mix deps.get

# Generate a migration (server)
cd apps/cadence_server
mix ecto.gen.migration <name>

# Generate a migration (daemon)
cd apps/cadence_daemon
mix ecto.gen.migration <name> --repo Cadence.Daemon.Repo
```

Always run `mix format` before declaring a task complete.

---

## 7. Naming Conventions

| Thing | Convention | Example |
|---|---|---|
| Module | PascalCase, namespaced | `Cadence.Daemon.CommitQueue` |
| Function | snake_case | `create_node/2` |
| Node flag | atom, kebab-case | `:in-progress`, `:functioning` |
| Env var | `CAD_` + SCREAMING_SNAKE | `CAD_LLM_API_KEY` |
| Neovim command | `:Cad` + PascalCase | `:CadOpen`, `:CadFork` |
| Sync message | `Cadence.Shared.Sync.<Name>` | `Cadence.Shared.Sync.PushNodes` |
| Docker image | `cadence-<role>` | `cadence-server` |

Flag atoms are the exact set: `:functioning`, `:in-progress`, `:broken`,
`:sandbox`. Do not invent new flags without updating spec §3.1.

---

## 8. Testing Conventions

- Every public function in `cadence_shared` gets a test.
- `GitStore` gets an integration test that does a full round-trip (init →
  blob → tree → commit → read) on a temp directory.
- Daemon integration tests use `ExUnit` + `Bypass` for the cloud sync client.
- Server tests use `Phoenix.ConnTest` for controllers and `Phoenix.LiveViewTest`
  for LiveViews.
- No tests hit real LLM APIs. Use a mock (e.g., `Mox`) or a recorded fixture.

---

## 9. AI Integration Rules

The spec calls for AI assistance in three places:

1. Commit message generation (spec §5.5)
2. Meld/union resolution (spec §6.5)
3. Documentation automation (spec §9.3)

For all three:

- Prompt templates live in `cadence_shared/priv/prompts/` as plain text files.
  Do not inline prompts in Elixir code.
- Every LLM call records the provider, model, and prompt version in the
  result metadata. Reproducibility matters.
- AI output is **always** reviewable and reversible. Never make an AI decision
  the final word on a user's behalf.
- Rate-limit all LLM calls via `Hammer`. The rate limiter is shared across
  the daemon.

---

## 10. Spec Cross-Reference

| Topic | Section |
|---|---|
| Vision & use cases | §1 |
| Architecture | §2 |
| Terminology | §3 |
| Data model | §4 |
| Daemon & auto-commit | §5 |
| DAG, fork, switch, union | §6 |
| Web UI & portfolio | §7 |
| Docker actions | §8 |
| Documentation automation | §9 |
| Sync protocol | §10 |
| Technology stack | §11 |
| Deployment | §12 |
| Build order | §13 |
| Non-goals | §14 |
| Guiding principles | §15 |
| Open decisions | §16 |

When a task touches a specific area, read that section of the spec first.
Do not work from this file alone for anything non-trivial.

---

## 11. What "Done" Means

A task is done when:

- [ ] Code compiles (`mix compile` passes).
- [ ] Code is formatted (`mix format` applied).
- [ ] Relevant tests pass.
- [ ] New public functions have tests.
- [ ] No hardcoded config values were introduced.
- [ ] The change aligns with the relevant spec section, or the spec was
      updated with approval.
- [ ] If a dependency was added, spec §11 was updated with approval.
- [ ] If the session is ending, `docs/progress.md` is updated.

Do not declare "done" when only the first item is checked.

---

## 12. Agent Tooling (OpenCode + Elixir/Phoenix skills)

<!-- ELIXIR-PHOENIX-PLUGIN:START -->
<!-- Hand-maintained OpenCode port of /phx-init | 2026-11-05 | plugin v3.2.2 -->
<!-- Stack: Phoenix 1.8, Ecto 3.14, Ash 3.36 (server only), LiveView 1.2 -->

OpenCode V2 reads `AGENTS.md` only — it does **not** fall back to `CLAUDE.md`.
`/phx-init` therefore has no effect here and must not be run. This block is the
manual equivalent: update it by hand when the plugin version changes (see
`docs/opencode.md`).

Skills are vendored under `.opencode/skills/elixir-phoenix/targets/opencode/skills/`
and are git-ignored; restore with `scripts/setup-opencode.sh`. Load one with
`@skill-id` or the `skill` tool. Slash commands such as `/phx-plan` are not
installed by this target.

Authority order: §4 Hard Rules, then `docs/spec.md`, then skill instructions.
If a skill contradicts the spec, stop and ask — do not improvise.

### Routing

| Request | Path |
|---|---|
| Bug, stack trace, unexpected behaviour | `@phx-investigate` |
| Single-file change (<50 lines), config, CSS | `@phx-quick` |
| Feature spanning 2+ contexts, new domain concept | `@phx-plan` → `@phx-work` → `@phx-review` |
| Auth, sessions, tokens, sync protocol | `@phx-plan`, plus `@security` — security work never skips planning |
| Scope still unclear | `@phx-brainstorm` |
| Domain reference while coding | `@ecto-patterns`, `@liveview-patterns`, `@testing`, `@ash-framework`, `@elixir-idioms` |
| Slow code, memory, call chains | `@phx-perf`, `@phx-trace` |
| End of a slice | `@phx-verify`, then `@phx-review` |

### Artifacts vs. session state

Skill workflows write to `.claude/plans/{slug}/` (plugin convention,
git-ignored). That is **run** state: research, scratchpads, review output.

- `phx-work` / `phx-full` resume ledger → `.claude/plans/{slug}/progress.md`.
- `docs/progress.md` stays the canonical session handoff (§2) and is still the
  only state the next session reads cold.
- At wrap-up, fold durable outcomes into `docs/progress.md`; promote reusable
  lessons into `docs/`. Do not let `.claude/solutions/` become a second
  knowledge base.

### IRON LAWS — stop and explain if code would violate one

**LiveView**
1. No DB query in a disconnected mount → `assign_async`.
2. Use streams for lists over ~100 items.
3. Check `connected?/1` before subscribing to PubSub.
4. Match `{:error, %Ecto.Changeset{}}` explicitly; a bare `{:error, _}` hides
   form errors.

**Ecto**
5. No `:float` for money → `:decimal` or integer cents.
6. Pin values with `^` in queries; never interpolate.
7. Separate queries for `has_many`, JOIN for `belongs_to`.

**Security**
8. No `String.to_atom/1` on user input.
9. Authorize every `handle_event`; mount auth is not enough.
10. No `raw/1` on untrusted content.

**OTP**
11. No process without a concurrency, state, or isolation reason.
12. Mix tasks: `Mix.Task.run("app.config")` +
    `Application.ensure_all_started/1`, never `app.start`.
13. Capture the Gettext/CLDR locale before spawning a Task or GenServer.

**Style**
14. Comments hold durable facts (footguns, quirks) — not change reasoning or
    issue tags. That belongs in the commit/PR.

### Ash (`cadence_server` only)

Load `@ash-framework` before writing Ash code. Prefer domain code interfaces
over direct `Repo` calls. `cadence_shared` schemas stay plain Ecto — Ash must
not leak across the app boundary (§3).

### Verification gate (umbrella root)

```bash
mix format --check-formatted &&
mix compile --warnings-as-errors &&
mix test
```

Focused loop first, e.g. `mix test apps/cadence_server/test/proposals_test.exs`.
`credo` and `dialyzer` are **not** configured in this umbrella — do not report
them as run. The `mix` formatter in `opencode.jsonc` reformats files after
edits; the gate still decides whether the tree is clean.

<!-- ELIXIR-PHOENIX-PLUGIN:END -->

## Appendix A — `docs/progress.md` Template

Create `docs/progress.md` using exactly this structure. Keep it current. The
next session reads it first.

```markdown
# Cadence — Progress

## Current Phase
Phase 1b — Shared schemas + GitStore

## Done
- [x] Node, Project, Membership schemas with changesets
- [x] Tests for schema validations

## Next
- `GitStore.init/1` — initialize a bare repo at a given path.
  Blocked on: deciding whether to use `Cadence.Shared.GitStore` directly or
  build a small porcelain layer first. See spec §5.2.

## Blocked
- (none)

## Spec Deltas
- (none)

## Last Updated
2026-10-XX — session ended after schema work
```

### Notes on maintaining this file

- **Done** is a concise current-phase summary. The full running log lives in
  `docs/archive/progress-history.md`; add to it only when archiving a phase, not
  every session. Do not delete unresolved items from **Spec Deltas**.
- **Next** is replaced each session. It should describe *one* immediate step,
  not a phase.
- **Blocked** is replaced each session. If empty, write `(none)` explicitly —
  don't leave the section absent.
- **Spec Deltas** is cumulative for unresolved items. When a delta is
  resolved (spec updated), move it to **Done** and remove it from this
  section.
- **Last Updated** is always today's date and a one-line note about how the
  session ended.
