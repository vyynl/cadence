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
│   ├── phase-3-prep.md         current phase brief
│   └── phase-2b-*.md           historical Phase 2b briefs
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

- **Done** is cumulative. Do not delete completed items from previous
  sessions; append this session's completions. The file is a running log.
- **Next** is replaced each session. It should describe *one* immediate step,
  not a phase.
- **Blocked** is replaced each session. If empty, write `(none)` explicitly —
  don't leave the section absent.
- **Spec Deltas** is cumulative for unresolved items. When a delta is
  resolved (spec updated), move it to **Done** and remove it from this
  section.
- **Last Updated** is always today's date and a one-line note about how the
  session ended.
