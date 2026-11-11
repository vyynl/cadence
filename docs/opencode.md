# OpenCode Agent Tooling

How the Elixir/Phoenix agent skills are wired into this repository, and what
OpenCode does and does not enforce here.

`AGENTS.md` is the behavioral contract. This file explains the tooling around
it. `docs/spec.md` remains the product contract.

## What is installed

| Piece | Location | Notes |
|---|---|---|
| 51 Elixir/Phoenix skills | `.opencode/skills/elixir-phoenix/targets/opencode/skills/` | Vendored sparse checkout, **git-ignored** |
| Project config | `opencode.jsonc` | Formatter + destructive-command guards |
| Behavioral rules | `AGENTS.md` §12 | Manual port of `/phx-init` |
| Run artifacts | `.claude/plans/{slug}/` | Plugin convention, git-ignored |
| Session handoff | `docs/progress.md` | Canonical state (AGENTS.md §2) |

The upstream OpenCode target ships **skills only**. There are no plugin hooks,
no plugin-provided subagents, and no Tidewave MCP registration. Anything that
depends on Claude Code hooks or agents does not run here.

## Setup and updates

```bash
scripts/setup-opencode.sh          # install or update
scripts/setup-opencode.sh --check  # report state only
```

The plugin repository is deliberately not committed: it is a separate git
repository, so tracking it would record a broken gitlink. The script restores
it in a fresh clone.

After updating the plugin, check `targets/opencode/skills/phx-init/` for changes
to the injectable template and carry them into `AGENTS.md` §12 by hand.

## Invoking a skill

Use the `@` form or the `skill` tool:

```text
@phx-plan add public proposal route
@phx-review
```

Skills are advertised to the model by their frontmatter `description`, so
ordinary requests usually select the right one without naming it. Do not rely
on `/phx-plan`-style slash commands — this target does not install them.

| Task | Skill |
|---|---|
| Bug / stack trace | `phx-investigate` |
| Single-file change | `phx-quick` |
| Multi-context feature | `phx-plan` → `phx-work` → `phx-review` |
| Auth, sessions, sync | `phx-plan` + `security` |
| Unclear scope | `phx-brainstorm` |
| Domain reference | `ecto-patterns`, `liveview-patterns`, `testing`, `ash-framework`, `elixir-idioms` |
| Pre-PR gate | `phx-verify`, `phx-review` |
| Slow code / call chains | `phx-perf`, `phx-trace` |

## Project commands

Unlike the plugin's skills, commands live in this repository and work as
ordinary OpenCode slash commands.

| Command | Purpose |
|---|---|
| `/audit-100 [ids\|quick] [--auto-approve\|--plan-only\|--max-items N]` | Supervise the `docs/audit-100-plan.md` work: one child session per item, sequential integration, per-item gate + read-only review, commit only on approval, then refresh the audit and the handoff. Defined in `.opencode/commands/audit-100.md`. |

Project commands are discovered from `.opencode/commands/` and reload without a
restart. Editing the file changes the command immediately. Commands are
prompts, not hooks: the supervisor's rules (serial writers, approval gates, no
pushes) are enforced by the command text and by OpenCode permissions, not by a
plugin.

## State and artifact conventions

Two different things are called "progress" — keep them apart:

| File | Owner | Lifetime |
|---|---|---|
| `.claude/plans/{slug}/progress.md` | `phx-work` / `phx-full` resume ledger (append-only events) | One plan run |
| `docs/progress.md` | Session handoff (AGENTS.md §2) | Whole project |

At wrap-up, fold durable outcomes from the run ledger into `docs/progress.md`,
and promote reusable lessons into `docs/` (spec delta, phase brief, or archived
history). `.claude/solutions/` is not a second knowledge base.

## Verification gate

```bash
mix format --check-formatted &&
mix compile --warnings-as-errors &&
mix test
```

`credo` and `dialyzer` are not dependencies of this umbrella; a report claiming
they ran is wrong. `opencode.jsonc` enables the built-in `mix` formatter, which
reformats Elixir files after edits — it does not replace the gate.

## Known gaps

- `/phx-init` writes `CLAUDE.md`, which OpenCode V2 ignores. Do not run it;
  edit `AGENTS.md` §12 instead.
- `phx-verify` mentions credo/dialyzer. Neither is configured here.
- Some skills describe Claude Code orchestration (background subagents, named
  agents). OpenCode has subagents, but the plugin's agent definitions are not
  shipped in this target.
- Tidewave MCP is not registered. Add it with `opencode mcp add` if a running
  app is available; the skills treat it as optional.

## Troubleshooting

- **A skill is missing:** confirm the file is `<id>/SKILL.md` under the target
  skills directory and that the frontmatter has a `description`.
- **Wrong content loaded:** a later source defines the same skill ID. Check
  `.claude/skills`, `.agents/skills`, and `~/.config/opencode/skills`.
- **Config not applied:** OpenCode reloads config on save; use `/reload` if a
  change does not land.
