# Cadence — Self-Hosted Source Control Warehouse

**Canonical spec.** This document is the source of truth for the Cadence
project. Anywhere the codebase or older notes refer to `superposition` /
`Superposition`, treat that as an obsolete placeholder — the project is
**Cadence**.

- Elixir module namespace: `Cadence.*`
- Environment variable prefix: `CAD_*`
- Neovim command prefix: `:Cad*`
- Docker image: `cadence-server`
- Umbrella apps: `cadence_shared`, `cadence_daemon`, `cadence_server`

A local-first, self-hosted source control system designed around a **DAG of
session nodes** rather than Git's branch model. Built in Elixir.

---

## 1. Vision

Cadence is a source control system for a single developer, a small team, or a
self-hosted company — optionally exposing a read-only public view — that
removes the friction of Git's branch model while preserving a complete,
navigable history.

The core idea: **every working session becomes a node in a directed acyclic
graph.** There is no `main`. There are no branches in the Git sense. There is
only a graph of snapshots, each tagged with a lifecycle flag, and a per-user
pointer that says "this is the node I'm currently working from."

The system is:

- **Invisible by default.** If the user has to think about version control, the
  design has failed.
- **Local-first, cloud-optional.** Everything except unions works offline.
- **DAG-native.** No `main`, no branches — just nodes and flags.
- **AI-assisted, never AI-decided.** Flags, melds, and docs are always
  human-reviewable and reversible.
- **Self-hosted.** The server runs on the owner's hardware (TrueNAS), not a
  third-party SaaS.

### Primary use cases

1. **Portfolio showcase.** A public, read-only web view of projects with
   rendered docs, DAG visualization, and optional interactive notebooks.
2. **Personal workflow.** A Neovim plugin that makes committing, spawning, and
   switching between work states frictionless.
3. **Experimentation.** Sandbox nodes spawned from the current node that let
   the user explore large features
   without disturbing the current line of work.
4. **Multi-machine continuity.** Work on machine A, resume on machine B, with
   session pointers synced through the server.

---

## 2. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  LOCAL MACHINE                                                   │
│                                                                  │
│  ┌─────────────┐   Unix socket / HTTP   ┌──────────────────┐    │
│  │  Neovim     │◄──────────────────────►│  Local Daemon    │    │
│  │  Plugin     │                        │  (Elixir/OTP)    │    │
│  └─────────────┘                        │                  │    │
│                                          │  - file watcher  │    │
│  ┌─────────────┐                        │  - local git repo│    │
│  │  Working    │◄────── watches ────────│  - commit queue  │    │
│  │  Directory  │                        │  - doc agent     │    │
│  └─────────────┘                        │  - sync ledger   │    │
│                                          │  - docker exec   │    │
│                                          └────────┬─────────┘    │
└───────────────────────────────────────────────────┼──────────────┘
                                                    │ HTTPS
                                                    ▼
┌──────────────────────────────────────────────────────────────────┐
│  CLOUD SERVER (Phoenix)                                          │
│                                                                  │
│  - Node store (mirrors local Git objects)                        │
│  - Multi-user DAG coordinator                                    │
│  - Union / meld worker                                           │
│  - Auth (AshAuthentication + OAuth)                              │
│  - Read-only portfolio web UI (LiveView)                         │
│  - Docker action runner (per-project containers)                 │
│  - Broadcasts (Phoenix.PubSub) for live graph updates            │
└──────────────────────────────────────────────────────────────────┘
```

### Key architectural principle

**Commits are local-first. Unions are server-first.**

- Committing, spawning, switching, and doc automation all happen locally and
  work offline.
- A union (meld) requires the server because it depends on the latest
  multi-user state and permission validation.
- The daemon and server communicate **only** via the HTTP sync protocol
  (§10). No shared runtime, no distributed Erlang, no shared process tree.

### Why two apps

The daemon and server have fundamentally different concerns:

| Concern | Daemon | Server |
|---|---|---|
| Database | SQLite (`ecto_sqlite3`) | Postgres |
| Web stack | None (Unix socket only) | Phoenix + LiveView |
| Filesystem | Watches user's project dirs | Doesn't touch user filesystems |
| Network | Outbound to cloud + LLM APIs | Inbound from clients |
| Release | Native binary per dev machine | Docker container on TrueNAS |
| Auth | Local user only | OAuth, multi-user roles |
| Docker orchestration | Rarely (maybe local actions) | Primary responsibility |

They share schemas, the sync protocol, the Git wrapper, and the LLM client
via `cadence_shared`. They do **not** share a runtime.

---

## 3. Core Concepts & Terminology

| Term | Meaning |
|---|---|
| **Node** | An immutable snapshot = one Git commit + metadata. The atomic unit of the graph. |
| **DAG** | The project's directed acyclic graph of nodes. |
| **Session pointer** | Per-user, per-project cursor indicating which node that user is currently editing from. |
| **Active head** | A node in a user's active heads set. Normally the most recent commit; spawns add the parent to this set. |
| **Spawn / Sandbox** | A new child node spawned from the current node, where the parent remains an active head. |
| **Meld / Union** | The DAG's *merge*: a new node with 2+ parents, combining divergent lines of work, created server-side by an AI coding agent. |
| **Flag** | Per-node lifecycle marker: `functioning`, `in-progress`, `broken`, `sandbox`. |
| **Pinned** | A set of nodes explicitly surfaced by the owner for public preview. |
| **Preview node** | The node shown to unauthenticated visitors. Derived, not stored. |
| **Doc agent** | A sub-process that revises project documentation after code changes, before commit. |

### 3.1 Flag semantics

- `functioning` — code is in a known-good state (tests pass, or user asserts).
- `in-progress` — partial implementation, no known breakage.
- `broken` — known failures, syntax errors, incomplete refactor.
- `sandbox` — a node explicitly spawned for exploration.

Flags may be set manually, suggested by the AI commit-message pass, or
inferred from heuristics (e.g., failing test detection).

**Never auto-promote a meld to `functioning` without validation.** The AI's
job is to produce the tree; the human's job is to verify it.

### 3.2 Commit vs. spawn

- **Normal commit** — pointer advances to the new child. The parent is
  implicitly superseded and removed from the user's active heads.
- **Spawn** — pointer advances to the new sandbox child. The parent **stays**
  in the user's active heads, reachable with a single `:CadSwitch`.
- **Switch** — moves the pointer to any node in the project's DAG without
  creating a node. Active heads are the usual targets and what the picker
  normally surfaces.

---

## 4. Data Model

### 4.1 Node

```
Node
  id                :uuid
  project_id        :uuid
  git_commit_sha    :string          # reference into the Git object store
  parents           :[uuid]          # empty for root, 1 for normal, 2+ for meld;
                                     # uuid[] + GIN index (edges table = migration path)
  flags             :[atom]          # subset of :functioning | :in-progress | :broken | :sandbox
  pinned            :boolean
  message           :string          # AI-generated, human-editable
  session_metadata  :map             # small: duration, files touched, model; no inline diffs
  created_by        :uuid
  created_at        :utc_datetime_usec
  docs_state        :atom            # :current | :pending | :skipped
```

`created_at` is microsecond-precision so node ordering (latest-node lookup,
picker list) reflects insertion order; ties are broken deterministically by
`id` (order by `created_at desc, id desc`). `parents` is stored as a `uuid[]`
array with a GIN index for cheap child lookup
(`WHERE parents @> ARRAY[x]`). If a project grows large enough that recursive
traversal slows, migrate to a normalized `node_edges(parent_id, child_id)`
table — the documented migration path. `session_metadata` must stay small:
diffs and doc-diffs are stored as Git objects (referenced by SHA), never
inlined into the row.

The **server** additionally stores a server-only `nodes.seq bigserial` column
(indexed) as the stable pull cursor. It is not part of the shared `Node`
schema, so the daemon's SQLite store is unaffected.

### 4.2 Project

```
Project
  id                :uuid
  name              :string
  slug              :string          # URL-safe
  owner_id          :uuid
  docs_schema       :map             # see §9
  docker_image      :string | nil
  actions_manifest  :map | nil
  created_at        :utc_datetime
```

### 4.3 Membership (per-user, per-project)

```
Membership
  user_id           :uuid
  project_id        :uuid
  role              :atom            # :owner | :trusted | :viewer
  active_heads      :[uuid]          # nodes this user considers active
  session_pointer   :uuid | nil      # node this user is currently editing from
  preferences_updated_at :utc_datetime_usec  # LWW version (nil = never synced)
  last_seen_at      :utc_datetime
```

`active_heads` and `session_pointer` are **user preference metadata**. They
sync to the cloud so your machines agree on where you left off.

### 4.4 Preview node resolution

```
pinned_sorted = project.nodes.filter(pinned).sort_by(created_at desc)
preview_node  = pinned_sorted.first
             ?? project.nodes.filter(:functioning).sort_by(created_at desc).first
             ?? project.nodes.sort_by(created_at desc).first
```

### 4.5 Roles & permissions

| Role | Commit | Spawn | Switch | Union | Approve | Pin | Delete | Manage members |
|---|---|---|---|---|---|---|---|---|
| `owner` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `trusted` | ✓ | ✓ | ✓ | ✓ | ✓* | ✗ | ✗ | ✗ |
| `viewer` | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| unauthenticated | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |

\* `trusted` may *propose* melds/promotions; whether they may *approve* them is
a per-project grant set by the owner (the basic "can/can't approve melds"
switch). See §6.6.

Public visitors are unauthenticated and see the full read-only DAG and public
repository snapshots (subject to §7.6 filtering); they never receive mutation
permissions.

### 4.6 Teams, approvers & supervisor (lightweight)

Cadence deliberately avoids an org-chart/HR model. For collaboration it
supports only lightweight, metadata-grade relationships:

- **Team** — a named set of users, optionally used to scope who may approve.
- **Approver** — a per-project boolean on a membership: can this user approve
  melds/promotions?
- **Supervisor** — an optional per-user pointer (e.g. "reports to"), used only
  for display/attribution in the DAG (edit/approval contexts). Not enforced.

None of these alter the DAG itself; they only shape *who may promote* a node
and how credit is displayed.

---

## 5. Phase 1 — Local Daemon & Auto-Commit

### 5.1 Responsibilities

- Watch registered project directories for file changes.
- Commit to a local Git object store using `Cadence.Shared.GitStore` (pure Elixir, no shell-out).
- Queue commits when offline; flush on reconnect.
- Run the doc-automation sub-process before final commit.
- Serve a Unix socket / local HTTP API to the Neovim plugin.
- Maintain a sync ledger for pending pushes, per-project pull cursors, and
  small sync metadata (server user ID, provisioning/backfill markers).

### 5.2 Supervision tree

```
Cadence.Daemon.Application
├── Cadence.Daemon.Repo                (SQLite via ecto_sqlite3)
├── Cadence.Daemon.LLMRateLimit        (Hammer, shared ETS)
├── Cadence.Daemon.AgentWorker         (Task.Supervisor for LLM calls)
├── Cadence.Daemon.MessageQueue        (async commit-message retry)
├── Cadence.Daemon.ProjectRegistry     (DynamicSupervisor)
│   └── Cadence.Daemon.ProjectSupervisor  (per project, :rest_for_one)
│       ├── Cadence.Daemon.CommitQueue (serialized commits per project)
│       └── Cadence.Daemon.Watcher     (file_system + debounce)
├── Cadence.Daemon.SyncLedger          (persistent pending queue + cursors)
├── Cadence.Daemon.SyncTasks           (Task.Supervisor for network cycles)
├── Cadence.Daemon.SyncWorker          (scheduler: one task per project)
└── Cadence.Daemon.API                 (Bandit/Plug, Unix socket)
```

`Cadence.Daemon.SyncClient` is a stateless Req wrapper used by sync tasks (it
is not a supervised child). `Cadence.Shared.GitStore` is stateless and lives in
`cadence_shared`; each project's `CommitQueue` holds a handle to its object
store. The doc agent (planned) will run as a supervised `Task` so it can be
cancelled if a new commit arrives.

**Design notes:**

- One `Watcher` per project. Uses `file_system` to receive events, debounces
  with a `:timer` (default 2s idle before triggering a commit, configurable via
  `CAD_WATCH_DEBOUNCE_MS`).
- `CommitQueue` is a `GenServer` that serializes commits per project so two
  rapid saves don't race.
- `AgentWorker` is a `Task.Supervisor` with a rate limiter (`Hammer`) because
  LLM calls are the most expensive resource.
- `ProjectSupervisor` uses `:rest_for_one`, so if the commit queue crashes the
  watcher that feeds it restarts too; a watcher-only crash restarts just the
  watcher.
- `SyncWorker` is a single scheduler; each project's push/pull cycle runs in a
  `SyncTasks` task. Network failures never block commits or the daemon API.
  Commits enqueue asynchronously, the worker retries with backoff, and boot
  rehydrate flushes pending work when sync is configured.

### 5.3 Commit pipeline

```
file event
  → debounce (2s idle)
  → snapshot working tree into the Git object store
      (build/dependency dirs and nested `.git` excluded; names via CAD_IGNORE)
  → if docs affected (per schema): run DocAgent (may defer if offline)
  → write revised docs to working tree
  → commit locally via Cadence.Shared.GitStore with a placeholder message
  → create Node record in local store
  → mark user's session_pointer = new node
  → asynchronously generate the commit message (LLM: code diff + doc diff)
      and update the node's message/flags; on failure retry with backoff while
      the placeholder remains (MessageQueue). The commit path never blocks on
      the LLM.
  → enqueue cloud sync
```

The parent of a normal commit is the node the local user is currently editing
from (their `session_pointer`), not the project's newest node — so switching to
an older node and committing branches from there (spec §3.2).

### 5.4 Offline behavior

- Commits always succeed locally.
- Doc automation: if offline, commit with `docs_state: :pending` and queue a
  doc-revision job. On reconnect, run the agent, amend the docs into a
  follow-up commit, then sync both as one logical node.
- Sync queue: a persistent list of `(local_node_id → cloud_node_id)` mappings.
  Flushed on reconnect. On conflict (cloud already has a child of the same
  parent), the node simply becomes a sibling — the DAG absorbs it.

### 5.5 AI commit messages

- Prompt the LLM with the diff and a strict format template.
- Return a short summary + optional flag suggestion.
- Store the model name in `session_metadata` for reproducibility.
- Human-editable in the Neovim picker before commit if the user wants.

**Prompt template (initial):**

```
You are generating a commit message for a session-based version control
system. Given the diff below, produce:

1. A one-line summary (max 72 chars).
2. A suggested flag: one of `functioning`, `in-progress`, `broken`.
3. Optional: 2–4 bullet points of detail if the change is non-trivial.

Respond in exactly this format:

SUMMARY: <one line>
FLAG: <functioning|in-progress|broken>
DETAIL:
- <bullet>
- <bullet>

Diff:
<diff>
```

### 5.6 Configuration

- Daemon configuration is environment variables only (see §12.6), supplied via
  a `.env` file or exported directly into the process environment.
- Secrets live in `~/.config/cadence/env` (chmod 600), never in source or
  `config/`.

---

## 6. Phase 2 — DAG, Spawn, Switch, Union

### 6.1 Neovim plugin commands

| Command | Behavior |
|---|---|
| `:CadOpen` | Open the DAG picker. Default selection = most-recent node by current user (after attempting a short cloud sync; fall back to local). |
| `:CadSpawn <name>` | Spawn a sandbox child from the current node. **Session pointer moves to the new node.** Parent stays in active heads. |
| `:CadSwitch <label>` | Move the session pointer to another node in the project (active heads are the usual targets) without creating a node. |
| `:CadUnion` | Enter picker in union mode. CR toggles `✓`. `<C-s>` submits to server. |
| `:CadDocDiff` | Show the doc diff attached to the current node. |
| `:CadDocSync` | Manually trigger doc automation. |

### 6.2 Picker UI

- Left-aligned floating **rail**, width `clamp(floor(terminal_cols * 0.2), 20, 60)`
  (configurable); `nowrap`, so wider layers scroll horizontally as the cursor
  moves. Optionally (`graph.wrap_width`) wide layers wrap into stacked sub-rows
  separated by a break marker instead.
- Nodes rendered as filled dots (`●`, or `◉` when pinned) with a highlight group
  per flag.
- Edges rendered with `│ ╲ ╱ ─` composed into a grid; each edge inherits its
  **child's** flag color.
- Full navigation: up/down/left/right between nodes.
- Hover (`CursorMoved`) → a side panel with committer, date/time, flag(s), the
  commit message, and a color-coded line diff against the parent.
- Auto-open: when `nvim` starts inside a registered project directory, the
  picker opens automatically.
- In union mode: CR toggles `✓`; footer shows selection count and submit hint.

### 6.3 Default selection logic

1. Attempt cloud sync with a short timeout (default ~500ms, configurable via
   `CAD_SYNC_TIMEOUT_MS`).
2. If sync succeeds: default to most-recent node by the current user.
3. If sync fails: default to most-recent node by the current user in the
   local repo.
4. If the user has never worked on this project: default to the preview node.

When `nvim` is opened **inside a project directory**, `:CadOpen`
auto-triggers. When opened with no directory, the user sees a project picker
first (Telescope integration), then the DAG picker.

### 6.4 Spawn semantics

- `:CadSpawn` creates a new child of the current node, flagged `sandbox`.
- **Session pointer moves to the new node immediately.**
- The parent is added to the user's `active_heads` set.
- The working tree is unchanged (same files), so no visual disruption.
- Contrast with a normal commit, where the parent is implicitly superseded
  and removed from active heads.

### 6.5 Union semantics

Union is **server-first**. Offline union is disallowed (command greys out).

Server pipeline:

1. Validate caller role (`owner` or `trusted`).
2. Fetch the Git trees for all selected parent nodes.
3. Run the AI meld agent with all trees + commit messages + flags.
4. Create the new node with `parents = selected_nodes`.
5. Set flag from agent output (`functioning` only if tests pass; otherwise
   `in-progress` or `broken`).
6. Persist, broadcast via `Phoenix.PubSub`.
7. All connected clients pull the new node.

The invoking user's session pointer advances to the meld node. Other users'
pointers stay where they are.

**Meld agent prompt template (initial):**

```
You are merging N divergent versions of the same project into a single
consolidated version. You have been given the full file trees of each
parent version and their commit messages.

Produce a single unified file tree that:
- Preserves all non-conflicting changes from every parent.
- Resolves conflicts by preferring the more complete implementation.
- Does not introduce syntax errors.
- Does not remove functionality present in any parent unless two parents
  directly contradict.

Output format: a series of file operations (CREATE / MODIFY / DELETE)
followed by the file contents for each.

Parents:
<parent 1 message> <parent 1 tree>
<parent 2 message> <parent 2 tree>
...
```

### 6.6 Proposals, review & promotion

Meld/union is the DAG's merge; **promotion** is what replaces "merge into a
branch." A meld is not created (or not promoted to the visible line) until a
human approves it.

- **Proposal** — a pending request to create a meld node, or to promote an
  existing node to `pinned`. Carries: parent node IDs, the resulting tree (for
  a meld), proposer, and status (`pending | approved | rejected`).
- **Shareable link** — every proposal has a stable URL that renders the parents,
  resulting diff/tree, flags, and status. It is meant to be pasted into
  Slack/email/whatever comms tool the team uses; Cadence hosts the *view*, not
  the conversation.
- **Approve/reject** — reviewers (owner, or `trusted` users granted `approve`)
  approve or reject. Lightweight: no inline comments or threads.
- **On approval** — the meld node is created (per §6.5) and/or the node is
  promoted (`pinned`). Only approval moves state; proposing is non-disruptive
  and does not move anyone's session pointer.
- **Guards** — a meld is still never auto-promoted to `functioning` (§3.1);
  approval promotes the *line*, validation sets the *flag*.

See §16 for open questions on the exact promotion target and proposal model.

---

## 7. Phase 3 — Web UI & Portfolio

### 7.1 Public views (unauthenticated)

- Portfolio index listing public projects.
- Project landing page: title, description, and a full read-only DAG.
- Repository browser for any node's commit snapshot: file tree, file viewer,
  and rendered README (§7.5).
- Preview-node summary with its flags and timestamp.
- Markdown-rendered docs via `MDEx`.
- Embedded Livebook notebooks for data-analysis projects (sandboxed).
- Actions panel (if the project exposes read-only actions).

Anonymous visitors see the **full read-only DAG** and may browse the repository
snapshot of any node. Public rendering is always passed through the server-side
secret filter (§7.6): sensitive paths are hidden and detected secrets are
redacted before HTML reaches the browser. Public access never grants mutation.

Public routes: `/` is the portfolio index, `/p/:slug` is the project home,
`/p/:slug/n/:node_id/tree/*path` is a directory view, and
`/p/:slug/n/:node_id/blob/*path` is a file view. `/auth`, `/sync`, `/health`,
and static paths are reserved.

### 7.2 Owner/trusted views (authenticated)

- All of the above, plus:
- Pin/unpin nodes (owner only; trusted members may not pin, §4.5).
- A read-only member list with roles/approver flags (owner/trusted only).
- Trigger actions.
- Manage memberships.
- Review and approve/reject meld proposals (shareable link).
- View doc diffs and approve/reject pending doc revisions.
- Explicitly reveal unfiltered file content for maintenance (the public and
  default authenticated views remain filtered; see §7.6).

### 7.3 DAG visualization spec

**Rendering:** SVG inside a Phoenix LiveView. The project home is a 25/75 split:
the DAG rail on the left and the repository browser on the right (§7.5). The
rail is left-aligned and the right pane owns the remaining width; on narrow
screens the panes stack with the DAG first.

Each node is a filled circle (`r ≈ 8`), fill color by flag:

| Flag | Color |
|---|---|
| `functioning` | green |
| `in-progress` | amber |
| `broken` | red |
| `sandbox` | blue/grey |
| `pinned` | ring highlight |

**Edge routing:** elbow path, diagonal to the target X, then straight down.

```
M px,py
L cx, py + |cx - px|
L cx,cy
```

With a slope guard: if `cy - py < |cx - px|`, the vertical segment is skipped
and the edge is a straight diagonal. For a steeper look, scale the horizontal
distance (e.g., `2 * |cx - px|` for ~63°).

Edge `stroke` inherits the **child's** flag color.

**Y-axis mapping:** topological depth, with a fixed per-layer spacing.

```
y_node = depth(node) * layer_height
```

`depth` is the longest path from any root (the same value served by the daemon's
`GET /graph` and used by the Neovim picker). Real timestamps are shown in the
hover/tooltip metadata rather than encoded into vertical distance. This keeps
the web DAG consistent with the picker and bounded regardless of gaps between
sessions. A time-clamped mapping remains a future option if historical spacing
becomes a product requirement; it is not part of Phase 3.

**Layout algorithm:** layered DAG (Sugiyama-style, simplified).

1. Depth = longest path from any root.
2. Order within layer by parent's horizontal position.
3. Enforce max layer width; wrap into sub-rows with a visual break marker.
4. Force left-align.

**Interactivity:** LiveView owns selection state. Hover shows a CSS tooltip
with the commit message and node status (flags/pinned) and highlights the node;
hover does not change the right pane. Click selects the node, patches the URL,
and swaps the right pane to that node's snapshot with a short crossfade. The
selected default node is marked. Nodes are focusable links so keyboard users get
the same behavior. In union mode (Phase 4), click toggles `✓` instead.

**Intro animation:** on the first full page load only, animate the default
node's ancestor lineage from its root(s) down to the default node along the
actual elbow paths (including the horizontal trajectory — not just a vertical
sweep). After the lineage reaches the default node's depth, pulse that node
2–3 times, then fade in any remaining nodes/edges and the right pane. The intro
does not replay on LiveView node selection; selection uses the crossfade above.
Timing is paced by `CAD_DAG_INTRO_MS` (default 1200); the repo pane reveals after
the default-node pulse. Large DAGs animate the lineage only, never every edge.
`prefers-reduced-motion` renders the final state immediately.

### 7.4 Auth

Humans sign in through `AshAuthentication` OAuth strategies (GitHub and
Google); roles per project are defined in §4.5. Daemons authenticate with a
personal access token modelled as an `AshAuthentication` **API key** (§10.1).

A signed-in human visits `/auth/tokens/new` and creates a daemon key with
`POST /auth/tokens`. The plaintext key is shown exactly once; only its hash is
stored. OAuth credentials are supplied through `CAD_OAUTH_*` env vars, so the
server can boot without OAuth configured (that provider's sign-in then fails).

Public visitors are unauthenticated and see the full read-only DAG and public
repository snapshots (subject to §7.6 filtering). Optionally, the deployment can
require a lightweight signed URL or API key to reduce scraping (deferred
decision).

### 7.5 Repository browser

The right pane is a read-only browser over the selected node's Git commit
snapshot. Each node stores `git_commit_sha`; the browser reads that commit's
tree from the project's server-side object store. It never reads the server's
filesystem working tree.

- **Home:** the current directory's entries (directories first, then files) and
  the rendered README for the selected node. The default selected node is the
  preview node.
- **Directory:** clicking a directory pushes a nested URL and lists that
  directory. Breadcrumbs return to any ancestor.
- **File:** clicking a file opens a clean read-only file view (escaped content,
  monospace, line numbers, horizontal scroll). Binary files show a metadata
  notice instead of content. A `README` is not repeated on a file view.
- **README:** resolved from the snapshot root, case-insensitively, preferring
  `README.md` and then common variants. Rendered through `MDEx` with raw HTML
  disabled. Missing READMEs show an explicit empty state.
- **URLs:** `/p/:slug/n/:node_id/tree/*path` for directories and
  `/p/:slug/n/:node_id/blob/*path` for files. LiveView patches these URLs so
  node/file views are shareable and survive reloads.
- **Limits:** file reads, README reads, directory listings, and the quarantine
  scan are bounded (`CAD_FILE_MAX_BYTES`, `CAD_FILE_MAX_LINES`,
  `CAD_README_MAX_BYTES`, `CAD_TREE_MAX_ENTRIES`, `CAD_SCAN_MAX_FILES`,
  `CAD_SCAN_MAX_BYTES`). Truncation is explicit in the UI, never silent. A
  snapshot that exceeds the scan caps is quarantined rather than shown
  unverified.

Code syntax highlighting is an open decision (§16); the first implementation
renders escaped, readable plain code. If highlighting is added, it must run
server-side or over already-redacted content so secret filtering cannot be
bypassed.

### 7.6 Public content safety (secret filtering)

Public repository browsing makes historical snapshots visible. Old
test/proof-of-concept nodes may contain hardcoded credentials. The server
therefore applies a mandatory, server-side filter to every anonymous render
(initial mount and every LiveView event):

1. **Sensitive paths** are hidden from the public tree by basename pattern
   (for example `.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa*`,
   `id_ed25519*`, `.npmrc`, `.pypirc`, `.netrc`, `.git-credentials`,
   `credentials*`, `secrets.*`). The UI may show a generic "hidden for security"
   count, never the hidden filename.
2. **Text content** is scanned for high-confidence secret patterns (provider
   tokens, private-key blocks, JWTs, generic `api_key`/`secret`/`token`/
   `password` assignments) before Markdown rendering, file rendering, or syntax
   highlighting. Detected values are replaced with `[REDACTED]`; private-key
   blocks and sensitive files are blocked entirely.
3. **Node quarantine.** If a high-confidence secret is detected anywhere in a
   node's snapshot (even in a file that would otherwise be redacted), that
   node's public repository snapshot is quarantined. The DAG still shows the
   node and its flags, but the public repo pane shows a generic "snapshot hidden
   for review" notice and returns no file tree, file content, or README. This is
   stricter than text redaction and prevents a partially-redacted snapshot from
   leaking a value the scanner missed elsewhere.
4. **Commit messages** shown in the DAG tooltip/node header are redacted with the
   same scanner.
5. **Binary files** are never rendered publicly.
6. **Authenticated raw view** is an explicit owner/trusted action (Phase 3d),
   never the default. Public and default authenticated renders stay filtered;
   owner/trusted members may toggle raw content for the selected node. Raw view
   bypasses redaction and quarantine only on the server, after a server-side
   role check; it resets when the selected node changes. Viewers and anonymous
   visitors cannot enable it.
7. **No content logging.** Scan results log counts/reasons only, never values or
   file content.

This is best-effort defense-in-depth, not a guarantee. Owners must still rotate
any secret that was ever committed. Per-project scan allowlists/overrides are
deferred (§16).

---

## 8. Phase 4 — Docker Actions Layer

### 8.1 Concept

Each project may define a `Dockerfile` (or use a language template) and an
`actions/` directory with a `manifest.json`. The server runs actions in
per-project containers via `ex_docker_api`.

Example manifest:

```json
{
  "actions": [
    {
      "name": "download_data",
      "command": "python actions/download_data.py",
      "description": "Fetch latest dataset",
      "expose": true
    },
    {
      "name": "run_analysis",
      "command": "jupyter nbconvert --execute analysis.ipynb",
      "description": "Run the analysis notebook",
      "expose": true
    }
  ]
}
```

### 8.2 Language support

Language-agnostic by design: the container is the abstraction. Cadence's
backend never parses Go/Python/Elixir source. It only:

1. Builds the image (once, cached).
2. Starts a container with the project's tree mounted.
3. Runs the action command.
4. Streams stdout/stderr back to the web UI or TUI.

Language templates for `Dockerfile` generation: Elixir, Python, Go, Node,
Rust, etc. These live in `cadence_server/priv/templates/`.

### 8.3 Isolation

- Containers run with no network by default unless the action opts in.
- CPU/memory limits via Docker cgroup flags.
- Read-only mount of project code; a separate writable volume for outputs.
- Action output is stored as an artifact attached to the node that triggered
  it, under `/data/artifacts`.

### 8.4 Security

- Docker socket access is the highest-risk surface. **Use a socket proxy**
  (`tecnativa/docker-socket-proxy` or equivalent) that allowlists only the API
  endpoints the action runner needs (`containers/*`, `images/*`, `exec/*`).
- Raw `/var/run/docker.sock` is acceptable only if the socket proxy is
  infeasible; even then, mount it read-only.
- `CAD_ACTIONS_ENABLED=false` disables the action layer entirely for
  deployments that don't need it.

---

## 9. Documentation Automation

### 9.1 Schema

Per-project `.caddocs.yaml`:

```yaml
index_file: README.md
docs_dir: docs/
sections:
  - name: Overview
    required: true
    max_words: 200
  - name: Architecture
    required: false
  - name: API
    generated_from: "lib/**/*.ex"
  - name: Changelog
    auto_append: true
```

### 9.2 Trigger conditions

Doc automation is **not** run on every commit. Gate on:

- Files matching a `generated_from` pattern changed, OR
- Commit touches a public API surface (exported functions, module attributes), OR
- Manual `:CadDocSync`.

### 9.3 Pipeline

```
code diff
  → DocAgent prompt: schema + current docs + diff
  → revised docs (only affected sections)
  → write to working tree
  → mark node docs_state: :current (or :pending if deferred)
```

**Prompt template (initial):**

```
You are updating project documentation. You have:
1. A documentation schema (below).
2. The current documentation files.
3. A code diff representing changes since the last commit.

Your task: update the documentation to reflect the code changes.

Rules:
- Preserve all existing content unless the diff makes it stale.
- Add sections only if the schema requires them.
- Never regenerate a file from scratch.
- For the index file, update it in place.
- Follow the schema's required sections exactly.

Output: a series of file operations (MODIFY / CREATE) with contents.

Schema:
<schema>

Current docs:
<docs>

Diff:
<diff>
```

### 9.4 Reviewability

- Doc diff stored as node metadata.
- `:CadDocDiff` shows it in Neovim.
- Web UI shows it with approve/reject buttons when `docs_state: :pending`.
- Reverting docs does not revert code — they're separate commits under one
  logical node.

### 9.5 Offline

If offline, commit with `docs_state: :pending`. On reconnect, run the agent,
amend docs into a follow-up commit, then sync both as one node.

### 9.6 Worker design

Doc agent runs in a **separate worker process** with its own rate limiter and
retry logic. This isolates the most API-cost-heavy component from the commit
pipeline.

Recommended: a `Task.Supervisor` per project with a `Hammer`-based rate
limiter shared across the daemon.

---

## 10. Sync Protocol (Local ↔ Cloud)

### 10.1 Authentication

The daemon authenticates to the server with a bearer token (personal access
token) issued by the server. The token is an `AshAuthentication` API key: the
server stores only its SHA-256 hash, and the plaintext is shown once at
issuance. It is stored in `~/.config/cadence/env` (chmod 600), never in source
or `config/`.

### 10.2 Local → Cloud

- Provision: before the first push, a daemon ensures the project exists via
  `POST /sync/projects` with its local project ID and metadata. The endpoint is
  idempotent by project ID; the first caller becomes the owner and repeat calls
  from an owner/trusted member succeed.
- Push: `POST /sync/nodes` with a batch of new local nodes (Git objects +
  metadata). A batch is scoped to one project and must be parents-first.
- The daemon's local node UUID is the cloud node ID; `PushNodesResponse`
  returns identity `{local_id, cloud_id}` mappings. This makes retries
  idempotent.
- Server verifies membership (`owner`/`trusted`), imports/validates Git
  objects, inserts nodes, broadcasts, and responds.
- Local ledger updated.

### 10.3 Cloud → Local

- Pull: `GET /sync/nodes?project_id=<uuid>&since=<cursor>`.
- The cursor is the server-only monotonic `nodes.seq` value; pulls are ordered
  by it and capped by `CAD_SYNC_PULL_LIMIT`.
- Local daemon fetches and merges into its local Git repo.
- Updates active heads and session pointer from the user's synced prefs.

### 10.4 Conflict handling

- If the cloud already has a child of the same parent, the pushed node simply
  becomes a sibling. No merge needed at the DAG level.
- Melds are the only operation that combines multiple parents, and they only
  happen server-side.

### 10.5 Active heads sync

Active heads and session pointer are stored per-user, per-project. They sync
with the same pull/push protocol but in a separate `preferences` channel.
This means opening a project on machine B resumes your session from machine A.

Preference writes are versioned by `preferences_updated_at`; a write wins only
when its timestamp is strictly newer than the stored value (last-write-wins).
Reads return the caller’s current preferences alongside the node pull.

Daemon preference sync is independent of the node queue: a local session
mutation bumps the version, and a background sync pushes it after pending nodes.
Remote preferences are applied only after the node batch is imported;
`active_heads` entries absent locally are dropped, and a `session_pointer` to
an unknown node is ignored (the local pointer is retained). Applied remote
versions are recorded as both remote and pushed so they are not echoed back.

The server broadcasts `{:sync_available, project_id}` after successful node
pushes and accepted preference writes. Daemons connect to `/socket/websocket`,
authenticate with an `x-cadence-token` header (never a query parameter), and join
`sync:user:<server_user_id>`. The channel is a **latency accelerator only**: it
carries a `sync_available` hint with `%{project_id}`, never DAG or preference
state, and polling remains the correctness fallback. `CAD_SYNC_CHANNEL_ENABLED=false`
disables the socket without disabling sync.

### 10.6 Message formats

Every Git object is transferred as:

```
%{sha: "40hex", type: "commit" | "tree" | "blob", data: base64(payload)}
```

`payload` is the raw object data without Git's `<type> <size>\0` header; the
receiver reconstructs the header and validates that `sha` matches the content.

```
SyncMessage.PushNodes
  nodes: [%{local_id, git_objects, metadata}]

SyncMessage.PushNodesResponse
  mappings: [%{local_id, cloud_id}]          # identity: cloud_id == local_id

SyncMessage.PullNodes
  project_id: uuid
  since: cursor
  response: %{nodes: [...], cursor: new_cursor}

SyncMessage.PullNodesResponse
  nodes: [...]
  cursor: new_cursor
  preferences: %{active_heads, session_pointer, updated_at} | nil

SyncMessage.PullNodesResponse nodes[]
  id, project_id, git_commit_sha, parents, flags, pinned, message,
  session_metadata, created_by, created_at, docs_state, git_objects

SyncMessage.PushNodes metadata
  project_id, git_commit_sha, parents, flags, message, session_metadata,
  created_at, docs_state, pinned
  # created_by is server-owned (the authenticated user)

SyncMessage.PushPreferences
  membership: %{project_id, active_heads, session_pointer, updated_at}

SyncMessage.Union
  project_id, parent_node_ids: [uuid]
  response: %{meld_node_id}
```

Node push errors are returned as `%{error: message, failed_local_id: uuid}` when
the failure is attributable to one node. Batches remain atomic (no partial node
inserts); the daemon can mark only that node failed and retry the rest.

---

## 11. Technology Stack

| Concern | Library / Tool |
|---|---|
| Daemon & server language | Elixir (OTP) |
| Web framework | Phoenix + LiveView |
| Git object store | `Cadence.Shared.GitStore` (native; implements Git's public object format) |
| File watching | `file_system` |
| LLM client | `axiom_ai` (DeepSeek via OpenAI-compatible base URL) |
| Markdown rendering | `MDEx` |
| Auth | `AshAuthentication` + `Ash` (daemon PATs use the API-key strategy) |
| Ash data layer | `ash_postgres` |
| Phoenix auth routes | `ash_authentication_phoenix` |
| Ash DSL formatting / codegen | `sourceror` (dev/test only) |
| LiveView test DOM | `lazy_html` (test only; required by `Phoenix.LiveViewTest`) |
| Docker API | `ex_docker_api` |
| Rate limiting | `Hammer` (declared in `cadence_shared`, used by the daemon's `LLMRateLimit`) |
| Graph model | `libgraph` |
| TUI (optional, daemon-side) | `ExRatatui` |
| Neovim plugin | Lua + plenary.nvim |
| HTTP client (daemon → cloud) | `Req` |
| Notification channel (daemon → server) | Phoenix Channels + `slipstream` |
| ORM / schemas | Ecto (`ecto`, `ecto_sql`) |
| JSON codec | `Jason` |
| HTTP server | `Bandit` |
| HTTP abstraction | `Plug` |
| Local persistent store | SQLite via `ecto_sqlite3` |
| Cloud database | PostgreSQL (`postgrex`) |
| PubSub | `Phoenix.PubSub` |
| SVG rendering (web) | Hand-rolled LiveComponent |

**Dependency discipline:** do not add dependencies beyond this list without
justification. If a new dependency is needed, add it to this table first.

**Browser assets:** the web UI serves the prebuilt `phoenix` and
`phoenix_live_view` browser bundles from the dependency priv directories plus a
small hand-written `app.js`. There is no Node/npm build step and no `esbuild`
dependency in Phase 3. If a syntax highlighter is added later, it must be
recorded here first.

---

## 12. Deployment Model

### 12.1 Umbrella structure

```
cadence/
├── apps/
│   ├── cadence_shared/    # schemas, sync protocol, LLM client, GitStore
│   ├── cadence_daemon/    # headless local process (mix release)
│   └── cadence_server/    # Phoenix + Postgres + Docker (container)
├── config/
├── docs/
│   ├── spec.md            # this document
│   ├── architecture.md
│   ├── daemon.md
│   ├── server.md
│   └── sync-protocol.md
├── mix.exs                # umbrella root
├── AGENTS.md              # agent conventions
└── docker-compose.yml     # server deployment
```

`cadence_shared` is a `path` dependency of both. It contains:

- `Cadence.Shared.Node`, `.Project`, `.Membership` (Ecto schemas)
- `Cadence.Shared.Sync.Message` (protocol types)
- `Cadence.Shared.GitStore` (git object store: blob/tree/commit; DAG-specialized, derived from `gitex`)
- `Cadence.Shared.LLM` (wraps `omni` / `axiom_ai`)
- `Cadence.Shared.RepoBehaviour` (adapter-agnostic queries used by both)

Both daemon and server define their own `Repo` module pointing at the shared
schemas, with different adapters (SQLite vs Postgres). Name them explicitly:

- `Cadence.Daemon.Repo`
- `Cadence.Server.Repo`

### 12.2 Daemon

- Distributed as a `mix release` installed per dev machine.
- No Phoenix, no Postgres, no LiveView.
- SQLite via `ecto_sqlite3` for local metadata.
- Unix socket API at `~/.local/state/cadence/daemon.sock`.
- Configuration: environment variables only (see §12.6), supplied via `.env`
  or the process environment; secrets in `~/.config/cadence/env` (chmod 600).
- Communicates with the server via the HTTP sync protocol (§10) plus an optional
  notification-only Phoenix Channels connection (Phase 2b-4). The socket never
  carries DAG or preference state.
- No distributed Erlang. No shared process tree with the server.

### 12.3 Server

- Distributed as a Docker image.
- Targets TrueNAS SCALE or any Docker host.
- Compose stack: app + Postgres + Docker socket proxy.
- Phoenix endpoint uses `Bandit.PhoenixAdapter` explicitly (Phoenix otherwise
  defaults to Cowboy2, which is not a Cadence dependency).
- All config via environment variables read in `config/runtime.exs`.
- Persistent volumes:
  - `/data/git` — bare Git repos / packfiles
  - `/data/artifacts` — action outputs
  - Postgres data
- Docker socket mounted read-only, preferably through a socket proxy.
- TLS terminated by the host's reverse proxy (TrueNAS built-in, Caddy, nginx).

### 12.4 docker-compose.yml (reference)

```yaml
services:
  cadence:
    image: ghcr.io/you/cadence-server:latest
    restart: unless-stopped
    ports:
      - "${CAD_HTTP_PORT:-4000}:4000"
    environment:
      CAD_PHX_HOST: "${CAD_PHX_HOST}"
      CAD_SECRET_KEY_BASE: "${CAD_SECRET_KEY_BASE}"
      CAD_DATABASE_URL: "ecto://${CAD_DB_USER}:${CAD_DB_PASS}@postgres/cadence"
      CAD_GIT_STORE_PATH: "/data/git"
      CAD_ARTIFACT_PATH: "/data/artifacts"
      CAD_OAUTH_GITHUB_CLIENT_ID: "${CAD_OAUTH_GITHUB_CLIENT_ID}"
      CAD_OAUTH_GITHUB_CLIENT_SECRET: "${CAD_OAUTH_GITHUB_CLIENT_SECRET}"
      CAD_OAUTH_GOOGLE_CLIENT_ID: "${CAD_OAUTH_GOOGLE_CLIENT_ID}"
      CAD_OAUTH_GOOGLE_CLIENT_SECRET: "${CAD_OAUTH_GOOGLE_CLIENT_SECRET}"
      CAD_LLM_PROVIDER: "${CAD_LLM_PROVIDER:-deepseek}"
      CAD_LLM_API_KEY: "${CAD_LLM_API_KEY}"
      CAD_LLM_MODEL: "${CAD_LLM_MODEL:-deepseek-chat}"
      CAD_LLM_BASE_URL: "${CAD_LLM_BASE_URL:-https://api.deepseek.com}"
      CAD_DOCKER_SOCKET: "${CAD_DOCKER_SOCKET:-http://docker-proxy:2375}"
      CAD_PUBLIC_URL: "https://${CAD_PHX_HOST}"
    volumes:
      - cadence_data:/data
    depends_on:
      postgres:
        condition: service_healthy
      docker-proxy:
        condition: service_started

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: "${CAD_DB_USER}"
      POSTGRES_PASSWORD: "${CAD_DB_PASS}"
      POSTGRES_DB: "cadence"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${CAD_DB_USER}"]
      interval: 5s
      retries: 10

  docker-proxy:
    image: tecnativa/docker-socket-proxy:latest
    restart: unless-stopped
    environment:
      CONTAINERS: 1
      IMAGES: 1
      EXEC: 1
      POST: 1
      BUILD: 1
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

volumes:
  cadence_data:
  postgres_data:
```

### 12.5 Configuration strategy

**Rule: everything configurable is an environment variable, read at runtime
via `config/runtime.exs`.** No build-time config for anything that might
change between deployments.

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  config :cadence_server, Cadence.ServerWeb.Endpoint,
    url: [host: System.fetch_env!("CAD_PHX_HOST"), port: 4000, scheme: "https"],
    secret_key_base: System.fetch_env!("CAD_SECRET_KEY_BASE"),
    server: true

  config :cadence_server, Cadence.Server.Repo,
    url: System.fetch_env!("CAD_DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("CAD_DB_POOL_SIZE", "10"))

  config :cadence_server,
    token_signing_secret:
      System.get_env("CAD_TOKEN_SIGNING_SECRET", System.fetch_env!("CAD_SECRET_KEY_BASE"))

  config :cadence_shared, Cadence.Shared.LLM,
    provider: System.fetch_env!("CAD_LLM_PROVIDER"),
    api_key: System.fetch_env!("CAD_LLM_API_KEY"),
    model: System.fetch_env!("CAD_LLM_MODEL"),
    base_url: System.get_env("CAD_LLM_BASE_URL")

  config :cadence_server, Cadence.Server.Actions,
    docker_socket: System.get_env("CAD_DOCKER_SOCKET", "http://localhost:2375"),
    enabled: System.get_env("CAD_ACTIONS_ENABLED", "true") == "true"
end
```

### 12.6 Environment variable contract

Every configurable value is an env var with a sensible default. Prefix: `CAD_`.

**Server:**

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `CAD_PHX_HOST` | yes | — | Public hostname |
| `CAD_SECRET_KEY_BASE` | yes | — | Phoenix secret |
| `CAD_LIVE_VIEW_SALT` | no | `CAD_SECRET_KEY_BASE` | LiveView static-token signing salt |
| `CAD_TOKEN_SIGNING_SECRET` | no | `CAD_SECRET_KEY_BASE` | JWT/AshAuthentication signing secret |
| `CAD_DATABASE_URL` | yes | — | Postgres connection |
| `CAD_DB_POOL_SIZE` | no | `10` | Ecto pool |
| `CAD_GIT_STORE_PATH` | no | `/data/git` | Git object storage |
| `CAD_SYNC_PULL_LIMIT` | no | `100` | Max nodes returned per pull batch |
| `CAD_DAG_INTRO_MS` | no | `1200` | First-load DAG/repo intro animation duration |
| `CAD_FILE_MAX_BYTES` | no | `524288` | Max bytes rendered in the public file viewer |
| `CAD_FILE_MAX_LINES` | no | `2000` | Max lines rendered in the public file viewer |
| `CAD_README_MAX_BYTES` | no | `262144` | Max README bytes rendered publicly |
| `CAD_TREE_MAX_ENTRIES` | no | `1000` | Max directory entries returned by the repo browser |
| `CAD_SCAN_MAX_FILES` | no | `10000` | Max files scanned for secret quarantine |
| `CAD_SCAN_MAX_BYTES` | no | `16777216` | Max snapshot bytes scanned for secret quarantine |
| `CAD_ARTIFACT_PATH` | no | `/data/artifacts` | Action outputs |
| `CAD_OAUTH_GITHUB_CLIENT_ID` | no | — | GitHub OAuth |
| `CAD_OAUTH_GITHUB_CLIENT_SECRET` | no | — | GitHub OAuth |
| `CAD_OAUTH_GOOGLE_CLIENT_ID` | no | — | Google OAuth |
| `CAD_OAUTH_GOOGLE_CLIENT_SECRET` | no | — | Google OAuth |
| `CAD_LLM_PROVIDER` | yes | — | `deepseek` \| `openai` \| `anthropic` \| … |
| `CAD_LLM_API_KEY` | yes | — | Provider key |
| `CAD_LLM_MODEL` | no | provider default | Model ID |
| `CAD_LLM_BASE_URL` | no | provider default | Base URL (DeepSeek: `https://api.deepseek.com`) |
| `CAD_DOCKER_SOCKET` | no | `http://localhost:2375` | Docker API (via proxy) |
| `CAD_ACTIONS_ENABLED` | no | `true` | Disable action layer |
| `CAD_PUBLIC_URL` | yes | — | Canonical URL for links |
| `CAD_HTTP_PORT` | no | `4000` | Host port binding |

**Daemon:**

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `CAD_SERVER_URL` | no | — | Cloud sync target (absence ⇒ offline mode) |
| `CAD_AUTH_TOKEN` | no | — | Personal access token (absence ⇒ offline mode) |
| `CAD_PROJECTS_ROOT` | no | `~/code` | Where projects live |
| `CAD_STATE_DIR` | no | `~/.local/state/cadence` | Socket, cache |
| `CAD_CONFIG_DIR` | no | `~/.config/cadence` | TOML + env |
| `CAD_LLM_PROVIDER` | yes | — | Same as server |
| `CAD_LLM_API_KEY` | yes | — | Same as server |
| `CAD_LLM_MODEL` | no | provider default | Same as server |
| `CAD_LLM_BASE_URL` | no | provider default | Same as server |
| `CAD_WATCH_DEBOUNCE_MS` | no | `2000` | Idle before commit |
| `CAD_WATCH_BACKEND` | no | `fs_inotify` | `file_system` backend (`fs_poll` in tests) |
| `CAD_LOCAL_USER_ID` | no | `00000000-0000-0000-0000-000000000000` | Local user UUID used for `created_by` and membership |
| `CAD_GIT_AUTHOR_NAME` | no | `cadence` | Author name written into local Git commits |
| `CAD_GIT_AUTHOR_EMAIL` | no | `cadence@local` | Author email written into local Git commits |
| `CAD_SYNC_ENABLED` | no | `true` | Enable automatic background sync |
| `CAD_SYNC_CHANNEL_ENABLED` | no | `true` | Enable the optional notification socket (polling remains active) |
| `CAD_SYNC_TIMEOUT_MS` | no | `500` | Picker sync attempt |
| `CAD_SYNC_REQUEST_TIMEOUT_MS` | no | `5000` | Background sync HTTP request timeout |
| `CAD_SYNC_INTERVAL_MS` | no | `30000` | Delay between background sync passes |
| `CAD_SYNC_RETRY_BACKOFF_MS` | no | `30000` | Base retry delay for failed sync operations |
| `CAD_SYNC_MAX_ATTEMPTS` | no | `10` | Max automatic retries for a pending node |
| `CAD_SYNC_PUSH_LIMIT` | no | `100` | Max nodes per push batch |
| `CAD_IGNORE` | no | `_build,deps,node_modules,.venv,venv,__pycache__,.elixir_ls,target` | Comma-separated entry names skipped when snapshotting the working tree (`.git` is always skipped) |
| `CAD_LLM_TIMEOUT_MS` | no | `5000` | LLM request timeout |
| `CAD_LLM_RATE_LIMIT` | no | `10` | LLM calls per rate window |
| `CAD_LLM_RATE_SCALE` | no | `60000` | Rate window in milliseconds |
| `CAD_LLM_DIFF_MAX_BYTES` | no | `32768` | Max diff bytes sent to the LLM |
| `CAD_LLM_RETRY_ATTEMPTS` | no | `3` | Max background commit-message attempts |
| `CAD_LLM_RETRY_INITIAL_MS` | no | `0` | Delay before the first background commit-message attempt |
| `CAD_LLM_RETRY_BACKOFF_MS` | no | `5000` | Linear retry backoff unit |
| `CAD_DIFF_MAX_FILES` | no | `20` | Max files in a node diff (hover preview) |
| `CAD_DIFF_MAX_LINES_PER_FILE` | no | `400` | Max diff lines per file |
| `CAD_DIFF_MAX_BYTES` | no | `262144` | Max combined file size diffed for a hover preview; larger files are marked truncated without running Myers |

### 12.7 First-boot sequence (server)

1. Generate `CAD_SECRET_KEY_BASE` via `mix phx.gen.secret`.
2. Create OAuth apps; set redirect URIs to
   `https://<CAD_PHX_HOST>/auth/<provider>/callback`.
3. Create TrueNAS dataset for `/data/git` and `/data/artifacts`, or bind-mount
   host paths.
4. Postgres volume initialized on first run.
5. Run migrations:
   ```
   docker compose run --rm cadence /app/bin/cadence eval \
     "Cadence.Server.Release.migrate()"
   ```
6. Configure reverse proxy for TLS.
7. Confirm the Docker socket proxy is reachable.

### 12.8 Build & release

- **Server image:** multi-stage Dockerfile. Build stage compiles the umbrella
  with `MIX_ENV=prod`; release stage produces a minimal image (Debian slim or
  Alpine + Erlang runtime, or a fully static build via `burrito` if feasible).
- **Daemon release:** `mix release cadence_daemon` per target OS. Optionally
  wrapped by `burrito` for a single-file binary.

### 12.9 Security notes

- Docker socket access is the highest-risk surface. Always use the socket
  proxy. Never expose the raw socket to the Cadence container in a
  publicly-reachable deployment.
- The daemon's auth token is a bearer token issued by the server. Store it in
  `~/.config/cadence/env` (chmod 600), never in source or `config/`.
- All sync traffic over HTTPS only.
- Actions are opt-in per project and disabled server-wide with
  `CAD_ACTIONS_ENABLED=false` if the deployment doesn't need them.

---

## 13. Suggested Build Order

**Phase 1a — Skeleton (week 1–2)**
- `mix new cadence --umbrella`.
- Create `cadence_shared`, `cadence_daemon --sup`, `cadence_server --sup`.
- Write README, AGENTS.md, docs/spec.md.
- Add dependencies to each `mix.exs`.
- Get `mix compile` passing with empty modules.

**Phase 1b — Shared schemas + GitStore (week 3)**
- `Node`, `Project`, `Membership` Ecto schemas in `cadence_shared`.
- Changesets.
- `Sync.Message` protocol structs.
- `Cadence.Shared.GitStore`: init (bare/working), write/read blob,
  build/read tree, write/read commit (explicit parents, no refs), checkout.
  Full round-trip test on a temp directory.

**Phase 1c — Daemon watcher + commit queue (week 4)**
- `file_system` watcher with debounce.
- `CommitQueue` GenServer per project.
- Static commit message first (no AI).
- SQLite persistence via `Cadence.Daemon.Repo`.

**Phase 1d — Daemon Unix socket API (week 5)**
- `Plug` + `Bandit` on a Unix socket.
- Endpoints: `GET /nodes`, `POST /spawn`, `POST /switch`, `GET /projects`.
- Tiny CLI client to test.

**Phase 1e — Neovim plugin, minimal (week 6)**
- Single Lua file talking to the daemon socket.
- `:CadOpen` lists nodes in a floating window.
- `:CadSpawn` spawns a sandbox child node.
- `:CadSwitch` moves between active heads.

**Phase 1f — AI commit messages (week 7)**
- `AgentWorker` with `omni`/`axiom_ai`.
- Prompt template + format guardrails.
- Store message on node.

**Phase 2a — DAG picker (week 8–9)**
- Daemon serves the structural graph via `GET /graph`: per-node topological
  depth, parent→child edges, session state, and the resolved default/preview
  node (§6.2, §6.3). Coordinate/glyph layout stays in the client.
- Daemon serves a per-node line diff via `GET /diff?project_id=&node_id=` for
  the hover preview (node vs. first parent).
- Render nodes + edges in the floating window with the elbow layout.
- Navigation, hover tooltips, default selection logic.
- `:CadUnion` picker mode (UI only, no server yet).

**Phase 2b — Cloud sync (week 10–11)**
- Phoenix server scaffold (manual, no `mix phx.new`).
- Auth with `AshAuthentication`: GitHub/Google OAuth for humans; API keys for
  daemons, issued via the OAuth-session-guarded `POST /auth/tokens`.
- Server migrations: shared project/DAG tables (`parents uuid[]` + GIN) plus
  accounts, and a server-only `nodes.seq bigserial` pull cursor.
- `GET /sync/me` bearer-check diagnostic (temporary; replaced by real sync
  routes in 2b-2).
- Project provisioning endpoint (`POST /sync/projects`).
- Push/pull endpoints.
- Sync ledger, HTTP client, orchestrator, and background worker on the daemon
  side; commit/spawn enqueue hooks and boot rehydrate.
- `POST /sync/preferences` with LWW versioning; preferences included in node
  pulls; optional Phoenix Channels `sync_available` notifications; partial-batch
  failure isolation.

**Phase 3 — Web UI (week 12–13)**
- 3a — UI foundation: direct web deps, layout/error HTML, `Portfolio` read
  context, `GitStore` path reader, public `/p/:slug` preview-node page.
- 3b-1 — LiveView project home: endpoint `/live` socket, prebuilt LiveView
  assets, `ProjectLive.Show`, 25/75 DAG + inspector shell, depth-based
  `DAGLayout`, SVG component, nested node URLs, lineage intro animation, hover
  tooltip, click-to-select.
- 3b-2 — Repository browser: `GitStore` directory listing, file viewer,
  README/MDEx rendering, nested tree/blob URLs, mandatory public secret
  filtering, size/entry caps.
- 3c — Public portfolio index, canonical metadata, and remaining public-page
  polish.
- 3d — Authenticated owner/trusted controls: pin/unpin, membership views,
  explicit unfiltered reveal.
- Review/promotion UI is deferred to Phase 4; no approval actions ship before
  the meld/proposal backend.

**Phase 4 — Unions & review (week 14–15)**
- 4a — Proposal model/API: pending meld/promotion lifecycle, reviewers,
  approve/reject, shareable token/URL, idempotent state transitions.
- 4b — Server-side meld worker: permission checks, parent tree fetch, AI meld
  prompt, resulting tree/commit, validation guard (no auto-`functioning`).
- 4c — Review UI: parents/diff/tree/flags, approve/reject, shareable link,
  server-side authorization.
- 4d — Broadcast/pull convergence: approved meld reaches connected clients and
  daemons; resolve web-pin propagation if promotion must be visible locally.
- Proposal UI must not ship before 4a/4b exist; AI output stays reviewable and
  reversible.

**Phase 5 — Doc automation (week 16)**
- Doc schema parsing.
- Doc agent sub-process.
- Deferred docs when offline.

**Phase 6 — Docker actions (week 17+)**
- `ex_docker_api` integration.
- Action manifest parsing.
- Web UI action buttons + streaming output.

**Phase 7 — Storage engineering (week 18+)**
- Server-side lossless repack: pack loose objects into packfiles with delta
  compression (background job; read transparently through `GitStore`).
  Non-destructive — history is never pruned (§15).
- Sync object negotiation: existence handshake so clients don't re-push objects
  the server already holds.

---

## 14. Non-Goals

- Full Git protocol compatibility (no `git clone` / `git push` interop).
- Replacing Git as the storage layer — we implement Git's object format
  directly.
- Real-time collaborative editing (CRDT, etc.). Sessions are commit-based.
- A general-purpose CI/CD system. Actions are for the owner's convenience and
  portfolio demonstration.
- A hosted multi-tenant SaaS. Cadence is self-hosted per team/org, with no
  org-chart/HR machinery (see §4.6).

---

## 15. Guiding Principles

1. **Invisible by default.** If the user has to think about version control,
   the design has failed.
2. **Local-first, cloud-optional.** Everything except unions works offline.
3. **The DAG is the model.** No `main`, no branches — just nodes and flags.
4. **AI assists, never decides.** Flags, melds, and docs are always
   human-reviewable and reversible.
5. **Left-aligned, bounded, readable.** The visualization must stay legible
   even for projects with hundreds of nodes over years.
6. **One language, one process tree.** Elixir/OTP for the daemon and server;
   everything else runs inside containers or as plugin clients.
7. **Config via environment.** Every configurable value is an env var with a
   default. Nothing hardcoded.
8. **Security by default.** Socket proxy over raw socket, TLS only, tokens in
   `chmod 600` files.

---

## 16. Open Decisions

- [x] **Public DAG visibility (Phase 3):** resolved — anonymous visitors see the
      full read-only DAG and may browse any node's repository snapshot (§7.1,
      §7.5), subject to mandatory server-side secret filtering (§7.6). Public
      access never grants mutation.
- [x] **Web DAG Y-axis (Phase 3):** resolved — topological depth with fixed
      layer spacing, consistent with the Neovim picker; timestamps appear in
      hover metadata (§7.3). Time-clamped spacing is deferred.
- [x] **Y-axis curve:** resolved for Phase 3 — depth-based spacing has no
      curve. Revisit only if time-clamped spacing is adopted.
- [x] **Public raw/filtered member view:** resolved in 3d — public and default
      authenticated renders stay filtered; owner/trusted members get an explicit
      raw toggle for the selected node. It resets on node change; viewers and
      anonymous visitors cannot enable it. Auditing the reveal action is
      deferred.
- [ ] **Pin propagation to daemons:** web pin/unpin is currently server-side
      only. The sync protocol pulls/inserts nodes but does not carry pinned-flag
      updates back to the daemon, so a web pin changes the public preview but not
      the local picker's pinned state. Revisit in a later sync-protocol slice.
- [ ] **Secret filter overrides:** per-project allowlists or custom patterns for
      legitimate files that trip the scanner. Deferred until false positives are
      observed.
- [ ] **Syntax highlighting:** plain escaped code vs. a server-side highlighter
      (e.g. Makeup) vs. a vendored client-side highlighter. Must be recorded in
      §11 before implementation.
- [ ] **Public flags:** the full public DAG exposes `broken`/`sandbox` nodes and
      their snapshots. Revisit if those should be members-only while keeping the
      rest of the DAG public.
- [ ] **Project visibility/publishing (Phase 3):** all projects are publicly
      discoverable by default (portfolio index + `/p/:slug`). A per-project
      `visibility`/`published` column and owner control are deferred until a
      concrete need appears; adding them later requires a migration.
- [ ] **Review/promotion UI placement:** the approval UI listed in §7.2 has no
      backend until Phase 4. Phase 3 ships at most a read-only placeholder;
      otherwise it is deferred entirely.
- [ ] **Doc agent model:** which LLM(s) to support, and whether to allow
      per-project overrides.
- [ ] **Local store:** SQLite via `ecto_sqlite3` is the obvious pick; confirm
      it fits the daemon's needs.
- [ ] **Neovim plugin distribution:** plain Lua files, or a proper plugin with
      lazy.nvim/packer specs.
- [ ] **Docker-in-Docker vs. host socket proxy:** host socket proxy is the
      current plan (§8.4). Revisit if isolation needs increase.
- [ ] **Public preview auth:** fully anonymous, or require a lightweight
      signed-URL / API key to avoid scraping.
- [ ] **Backup strategy for the cloud server:** Postgres WAL archiving +
      object store for Git packfiles.
- [ ] **Multi-user conflict UX:** when two trusted users spawn from the same
      node, how does the picker display the divergence?
- [ ] **Promotion target:** does approval promote to `pinned`, `functioning`,
      or a distinct "protected line" marker? (See §6.6.)
- [ ] **Proposal model:** approve/reject policy — any single approver, or a
      quorum of N? Should a rejected proposal be re-submittable?
- [ ] **Proposal visibility:** are shareable proposal links public (read-only)
      or authenticated-member-only? If public, the Phase 3 secret filter and
      raw-view rules must apply.
- [ ] **Meld flag validation:** without Phase 6 actions there is no test runner.
      Recommended baseline: AI meld starts `in-progress`; approval promotes/pins
      the line; never auto-promote to `functioning` until a real validator exists.
- [ ] **Team/supervisor schema:** exact shape and sync channel for the
      lightweight §4.6 relationships.
- [ ] **Proposal link format:** URL scheme and what the shareable view renders
      (diff vs. tree vs. flags).
- [ ] **Storage repack trigger:** when to run the Phase 7 lossless repack (size
      threshold vs. scheduled job), and the array→edges migration threshold.
- [x] **Daemon token issuance (Phase 2b):** resolved in 2b-1 — an
      OAuth-session-guarded `POST /auth/tokens` endpoint mints an
      `AshAuthentication` API key. No `mix` task or seeded token.
- [x] **Pull cursor representation (Phase 2b):** resolved in 2b-1 — server-only
      `nodes.seq bigserial` plus an index. See phase-2b plan §5.
- [ ] **Multi-node notification fan-out:** Phoenix Channels/PubSub broadcasts
      are local to one server node. Revisit if the server runs multi-node;
      polling remains the correctness fallback in the meantime.
- [ ] **Ash policy authorizer / SAT solver:** server Ash resources currently
      rely on controller-level checks rather than `Ash.Policy.Authorizer`.
      Revisit when the web UI exposes Ash actions directly; enabling policies
      requires adding `picosat_elixir` or `simple_sat` to spec §11.
- [x] **Push batch semantics (Phase 2b):** resolved in 2b-2 — fail-fast,
      single-project batches, parents-first ordering, and at most one parent per
      pushed node (melds stay server-side).
- [x] **Server-side project provisioning:** resolved in 2b-3 — the daemon
      ensures its local project exists via the idempotent
      `POST /sync/projects` endpoint (`Cadence.Server.Projects.provision/2`).
      The first caller becomes the owner; existing owners/trusted members can
      re-provision.

---

## 17. Glossary of File Paths

| Path                                        | Purpose                              |
|---------------------------------------------|--------------------------------------|
| `apps/cadence_shared/lib/cadence/shared/`   | Shared schemas, protocol, LLM client |
| `apps/cadence_daemon/lib/cadence/daemon/`   | Watcher, commit queue, socket API    |
| `apps/cadence_server/lib/cadence/server/`   | Phoenix, LiveView, meld worker       |
| `apps/cadence_server/priv/templates/`       | Dockerfile language templates        |
| `apps/cadence_server/priv/repo/migrations/` | Postgres migrations                  |
| `apps/cadence_daemon/priv/repo/migrations/` | SQLite migrations                    |
| `~/.config/cadence/env`                     | Daemon secrets (chmod 600)           |
| `<project>/.env`                            | Daemon/server env vars               |
| `~/.local/state/cadence/daemon.sock`        | Daemon Unix socket                   |
| `~/.local/state/cadence/cadence.db`         | Daemon SQLite database               |
| `/data/git`                                 | Server Git object storage            |
| `/data/artifacts`                           | Server action outputs                |
| `docs/spec.md`                              | This document                        |
