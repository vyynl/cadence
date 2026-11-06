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
| `:CadUnion` | Enter picker in union mode. CR toggles `✓` (2–8 nodes). `<C-s>` submits to the server and reports the proposal token/URL. |
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

Union is **server-first**. Offline union is disallowed: submission reports 503
when sync is unconfigured or unreachable (the picker itself is local and still
opens).

The server pipeline **proposes, it does not create**:

1. Validate the caller's role (`owner` or `trusted`) and load the parent nodes
   (2–8 distinct nodes, all belonging to the project; each parent retains up to
   the full scan cap in memory, so the list is capped).
2. Walk each parent snapshot under the public scan caps; a cap overflow or a
   missing object is an incident, never a partial meld.
3. Compute the deterministic union: paths on which every containing parent
   agrees are merged without AI involvement; only paths with differing blob
   SHAs are conflicts. Presence-versus-absence is not a conflict.
4. Run the meld agent **only on conflicting paths**, with a bounded prompt and
   a strict, allowlisted output format.
5. Validate the agent's file operations (conflict paths only, operation/file
   caps, no binary content, Elixir syntax for `.ex`/`.exs`) and materialize the
   result tree and commit. The commit's parents are the selected parent
   commits.
6. Create a **pending proposal** (§6.6) carrying the result tree/commit and
   reproducible agent metadata (provider, model, prompt version, counts). A
   pending meld for the same ordered parents is returned instead of running a
   duplicate union; rejected work is re-submitted as a new proposal.
7. Scan the result content for secrets; a finding keeps the proposal but opens
   a critical incident and isolates the result until resolved.

No node is created and no flag is promoted at this stage. `intended_flag` is
always `in-progress`; `functioning` remains validator-owned (§3.1). Approval
(4c) attaches/creates the node and moves the line. The proposing user's session
pointer does not move.

**Meld agent prompt contract (initial, `meld-v1`):**

- Input: parent messages/flags plus every version of each conflicting path.
- Output: `MELD_BEGIN`, then `FILE CREATE|MODIFY path` with a `<<<`/`>>>`
  content block, or `FILE DELETE path`, then `MELD_END`.
- Rules: only conflicting paths, each at most once, complete contents, preserve
  non-conflicting changes, prefer the more complete implementation, introduce
  no syntax errors, and remove no functionality unless two parents directly
  contradict.
- If the conflicts cannot all fit the context budget, the pipeline fails with a
  critical `scan_incomplete` incident rather than silently omitting paths.

### 6.6 Proposals, review & promotion

Meld/union is the DAG's merge; **promotion** is what replaces "merge into a
branch." A meld is not created (or not promoted to the visible line) until a
human approves it.

- **Proposal** — a pending request to create a meld node, or to promote an
  existing node. Carries: parent node IDs (melds), a nullable `target_node_id`
  (promotions), the precomputed result tree and commit (melds), proposer, and
  status (`pending | approved | rejected`). Meld results are materialized when
  the proposal is created so the resulting diff is reviewable before approval.
- **Shareable link** — every proposal has a stable, high-entropy token and URL.
  Proposal links are **public read-only by default**, consistent with the public
  project and DAG views. Anonymous and member views apply the same mandatory
  filtering/quarantine as §7.6; proposal result content is never rendered raw.
  Mutations (approve/reject/resolve) require authentication and the appropriate
  project role.
- **Approve/reject** — a single approver decides: the owner, or a `trusted`
  member with the per-project `approver` grant. The deciding user is the
  reviewer of record. Lightweight: no inline comments or threads.
- **On approval** — the meld node is attached/created (per §6.5) and/or the node
  is promoted to `pinned`. Only approval moves state; proposing is
  non-disruptive and does not move anyone's session pointer.
- **Approval mechanics (4c)** — the decision runs in a `FOR UPDATE` transaction
  that locks the project row and then the proposal row, so concurrent approvals
  of two proposals for the same result cannot attach two nodes. The stored
  result is verified before anything changes: for a meld the result commit must
  exist, its tree must be walkable under the §7.6 scan caps (an over-cap result
  is refused rather than half-checked), every object reachable from the result
  tree must be present, its tree must equal the proposal's `result_tree_sha`, and
  the first parent node and commit must still exist (a result whose diff could
  never have been shown is not approvable); a promotion has no result and always
  passes. A failed check rolls the decision back unchanged (status stays `pending`), opens
  a critical `scan_incomplete` proposal incident, and reports `integrity_failed`;
  an unverifiable result is never approvable. A meld approval then attaches the
  node carrying the result commit — reusing the existing node for that commit
  when there is one — with `parents = parent_ids`, flags `[in-progress]`,
  `pinned: true`, and `docs_state: pending`; a promotion approval pins its
  target node. Both fail closed (`blocked`) when an open critical node incident
  quarantines the node. Approval never sets `functioning` (§3.1): approval moves
  the line, validation sets the flag.
- **Creation and decision broadcasts (4c/4d/4e)** — a created pending proposal
  broadcasts `{:proposal_created, project_id, proposal_id}`; creation moves no
  node and no session pointer, so no daemon is woken. A successful decision
  broadcasts `{:proposal_decided, project_id, proposal_id, status}`. An approval
  that creates a node — or flips its `pinned` value — also broadcasts
  `{:nodes_pushed, project_id, [node_id]}`; approving an already-pinned target
  emits no node-changed event. Every successful decision additionally wakes each
  project member's daemon with `{:sync_available, project_id}` (§10.5). Refused
  decisions and refused or invalid creations broadcast nothing. Consumers filter
  on the ids they need (§7.2).
- **Guards** — a meld is still never auto-promoted to `functioning` (§3.1);
  approval promotes the *line*, validation sets the *flag*. Critical incidents
  (§6.7) block approval until resolved.

### 6.7 Critical findings & incidents

Security and correctness findings are persisted as server-side **incidents**
rather than only being recomputed on read. An incident may reference a proposal,
a node, both, or **neither** (project-scoped), and carries a kind
(`secret_detected`, `scan_incomplete`, `meld_failed`,
`agent_output_invalid`, `missing_objects`), severity (`critical | high`),
status (`open | resolved`), a redacted title, and scanner metadata only
(pattern names/counts; never secret values or file content).

- **Automatic creation** — server-side detection opens incidents when a meld
  proposal is built (4b) and when pushed node snapshots are scanned (4b-2).
  Meld failures can be project-scoped because no proposal exists yet.
- **Scope and severity** — `secret_detected` and `scan_incomplete` are
  `critical`: they isolate result content and block approval. `meld_failed`,
  `agent_output_invalid`, and `missing_objects` are `high`: visible alerts that
  do not isolate anything (there is no proposal to isolate). Only a
  proposal-linked critical incident isolates result content.
- **Isolation** — an open critical incident references the risky proposal or
  node. Proposal result content renders as a generic "hidden for review" notice
  and cannot be approved. A node with an open critical incident is quarantined
  on every public render, in addition to the scan-based quarantine in §7.6.
- **Resolution** — owner or granted approver may resolve an incident. Resolution
  re-runs verification; if the risk persists the incident stays open. There is
  no assignee or comment-thread workflow in Phase 4. Node snapshots are
  immutable, so a node incident resolves by **acknowledgment** (4b-2): no
  verification callback runs, and resolving it never bypasses the read-time
  scan in §7.6. A node whose snapshot genuinely contains a secret stays
  quarantined after its incident is resolved; the fix is to rotate the secret
  and push a new node. The review panel (4c) owns the resolution UX and
  presents this as rotate/resolve, not restore.
- **Proposal-linked resolution (4c)** — a proposal incident resolves only after
  a fresh scan of the stored result under the §7.6 caps. A remaining secret
  pattern or sensitive path keeps it open (`still_risky`): the result cannot be
  clicked clean, so the reviewer rejects the proposal and re-proposes with the
  secret rotated. A result that cannot be walked at all (missing objects, over
  the caps) also stays open (`unverifiable`). The same check re-asserts the
  §6.6 invariant that `meld_commit_sha`'s tree equals `result_tree_sha`, so an
  incident opened by a failed approval-integrity check cannot be dismissed
  while the mismatch holds (`integrity_failed`); the remedy there is also to
  reject and re-propose. A promotion-linked incident has no result to scan and
  resolves by acknowledgment. Project-scoped incidents resolve by
  acknowledgment like node incidents. Resolution never mutates a proposal;
  approval re-verifies the result independently (§6.6).
- **Authority** — the deterministic scanner is authoritative. LLM output may
  flag risk, but never decides whether content is safe.
- **Change broadcast (4e)** — a newly opened incident and an open→resolved
  transition broadcast `{:incidents_changed, project_id, incident_id,
  proposal_id, node_id}` on `project:<id>`, after the row commits. A duplicate
  open (same target and kind already open), an idempotent re-resolve, and a
  failed verification broadcast nothing. The payload carries ids only, never
  scanner metadata, and is best-effort: the write stands when broadcasting
  fails. Consumers filter by id: a proposal-linked event can change a proposal
  result's isolation, a node-linked event can quarantine that node, and a
  project-scoped event isolates nothing. Incident writes happen outside the
  caller's transaction so an uncommitted row is never announced.

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

Anonymous visitors see the **full read-only DAG** and may browse the repository
snapshot of any node. Public rendering is always passed through the server-side
secret filter (§7.6): sensitive paths are hidden and detected secrets are
redacted before HTML reaches the browser. Public access never grants mutation.
The Docker action panel is a member view (§7.2), not a public one; the manifest
file itself remains browsable as ordinary repository content.

Public routes: `/` is the portfolio index, `/p/:slug` is the project home,
`/p/:slug/n/:node_id/tree/*path` is a directory view,
`/p/:slug/n/:node_id/blob/*path` is a file view, and `/proposals/:token` is the
public read-only proposal page. `/p/:slug/reviews` and
`/p/:slug/reviews/:proposal_id` are member-only (authenticated, §7.2) and are
never public. `/auth`, `/sync`, `/health`, and static paths are reserved.

### 7.2 Owner/trusted views (authenticated)

- All of the above, plus:
- Pin/unpin nodes (owner only; trusted members may not pin, §4.5).
- A read-only member list with roles/approver flags (owner/trusted only).
- See the snapshot's Docker action list (any member) and trigger one
  (owner/trusted only, Phase 6b).
- Manage memberships.
- Review and approve/reject meld proposals (shareable link).
- The review hub: `/p/:slug/reviews` lists the project's proposals
  (pending first) and its open incidents, and
  `/p/:slug/reviews/:proposal_id` shows one proposal's parents/promotion
  target, the file-level result, integrity state, and decision state. Both
  routes are inside the authenticated live session and require project
  membership (`can_view?/1`); a refused visitor is redirected to the public
  project page with a flash. Only the owner or a granted approver
  (`can_decide?/1`) sees approve/reject and incident resolve controls, and
  every event re-checks that role. Proposal incidents are resolved only after
  a clean re-scan of the result (a remaining secret must be fixed by rejecting
  and re-proposing); node and project incidents resolve by acknowledgment
  (§6.7). Emails are shown to the owner/trusted manager audience only; other
  members see display names. Both pages subscribe to `project:<id>` once
  connected and refresh live: the hub on proposal creation/decision and on any
  incident change, the detail page only on its own decision, a
  proposal-linked incident, or an incident on the node it would promote or
  attach (an unrelated node incident is ignored; a critical one on that node
  blocks approval, so the page hides Approve rather than letting the click
  fail).
  Every handled event re-reads the membership before re-rendering controls, so
  a revoked grant disappears on the next project event; mutations still fail
  closed independently.
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

For the local demo stack (§12.4) a **compile-gated password strategy** may be
built in: `CAD_DEMO_AUTH=true` is read at build time
(`Application.compile_env`) and adds `password :demo` with
`registration_enabled?(false)` and `sign_in_enabled?(true)`, so seeded demo
accounts can sign in without OAuth credentials. A production build is made
without the flag and therefore contains no password strategy; additionally
`config/runtime.exs` raises when a prod boot sees `CAD_DEMO_AUTH=true`. The
demo password is public by design and never reused outside a local demo.

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
  `CAD_SCAN_MAX_BYTES`; proposal diffs also cap visible files at
  `CAD_PROPOSAL_MAX_FILES`). Truncation is explicit in the UI, never silent. A
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
   leaking a value the scanner missed elsewhere. An open critical incident for
   the node also forces quarantine on every read (§6.7), so isolation persists
   until the incident is resolved.
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
   file content. Proposal URLs are capability links: the server suppresses the
   default request access log for `/proposals/:token` so tokens are not written
   to production logs.

**Proposal results (4a-2 / 4c-3).** Proposal pages — public and the authenticated
review hub — render result *paths and statuses* only, never file content.
Sensitive paths are filtered out of the diff and reported as a generic count; a
high-confidence secret in a visible result file quarantines the whole result,
and an open critical incident isolates it (§6.7). Because no content is
rendered, files whose names are filtered out are not content-scanned for the
diff. Incident resolution scans differently: before a proposal incident is
resolved, every result blob — including blobs behind filtered path names — is
re-scanned, so a secret hidden by its filename still keeps the incident open.
Content rendering on the review surface remains deferred; when it lands, this
scope must be revisited so a hidden path's content cannot leak through a
different surface.

This is best-effort defense-in-depth, not a guarantee. Owners must still rotate
any secret that was ever committed. Per-project scan allowlists/overrides are
deferred (§16).

---

## 8. Phase 6 — Docker Actions Layer

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

The manifest is read from the selected node's snapshot at
`actions/manifest.json` — never from a server working copy. It is
client-pushed content, so parsing is strict and capped
(`CAD_ACTIONS_MAX_MANIFEST_BYTES`, `CAD_ACTIONS_MAX_ACTIONS`): names match
`^[a-z0-9][a-z0-9_-]{0,63}$`, commands are 1–512 bytes, descriptions are at
most 200 bytes, commands and descriptions reject control/bidi characters, and
duplicate names are rejected. Members may see the action list; running one
requires the owner/trusted role (Phase 6b). A missing, malformed, or oversized
manifest hides the panel or renders a shape-only notice — it never fails the
project page.

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

The file is the source of truth. It is parsed with `yaml_elixir` (§11) into the
`Project.docs_schema` map for local/server caching; an unreadable or invalid
schema never blocks a commit (the node records `docs_state: :skipped` plus a
shape-only error).

### 9.2 Trigger conditions

Doc automation is **not** run on every commit. Gate on:

- Files matching a `generated_from` pattern changed, OR
- Commit touches a public API surface (exported functions, module attributes), OR
- The documentation schema (`.caddocs.yaml`) itself changed, OR
- Manual `:CadDocSync`.

A manual `:CadDocSync` bypasses the automatic trigger re-check but still
respects `CAD_DOCS_ENABLED`; when disabled the daemon reports `skipped` with
`reason: "disabled"`. A node whose commit was already pushed is not rewritten:
any pushed-SHA stamp means the docs are attached as a follow-up child node
(§9.5), and the response is `202 queued` with the requested node's id. A node
whose docs are already generated (`docs_state: :current`) is reported as
`skipped: "already_current"`. A node with neither a `SyncPending` row nor a
pushed-SHA stamp is reported as `skipped: "legacy"`: it may have been pulled
from the server or may predate the stamp, so forcing docs could rewrite an
already-synced SHA. A manual job arms the same
`metadata["docs"]["state"] == "pending"` hold as an automatic job before it is
queued, so a local node cannot be pushed while the model runs; a pushed node has
no row to hold. When a manual skip or failure targets a docs-held **local**
node, the daemon releases it with the same terminal transition the job would
use (`skipped` or `deferred`) so it cannot stay out of the sync queue. A pushed
node keeps its deferred docs state, so a later retry can still attach the
child.

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

**Commit model (Phase 5).** The code change is committed first as `C1`. When
the agent succeeds, its docs are added to the working tree and written as a
follow-up commit `C2` whose Git parent is `C1`. The node's logical `parents`
(§4.1) do not change; its `git_commit_sha` points at `C2`, so one node contains
both code and docs while the two remain separate commits. A failed or deferred
generation leaves the node pointing at `C1` with `docs_state: :pending`. If the
node's current SHA is already on the server, the same generation is attached as
a docs child node instead of rewriting the snapshot (§9.5).

### 9.4 Reviewability

- The doc diff is derived on demand from the node's docs commit (`C2`) against
  its recorded `code_commit_sha` (`C1`), filtered to the schema's `index_file`
  and `docs_dir`. Both are Git objects; no diff is inlined in
  `session_metadata` (§4.1). The code change is never hidden or reverted.
- `:CadDocDiff` shows it in Neovim. A code-only node, a skipped generation, or
  an empty generation has no docs commit: the daemon returns `409` and the
  command reports that no docs diff exists. A missing `.caddocs.yaml` is also
  `409`, because the schema paths cannot be filtered.
- A read-only `docs_state` badge (`:pending`, `:current`, `:skipped`) is shown
  in the web UI. `:current` means the generation completed and its docs were
  committed as `C2`; an empty generation writes no `C2`, so
  `session_metadata["docs"]["docs_commit_sha"]` is absent and `"empty": true`
  is recorded. `:pending` means a job is queued, deferred offline, or failed
  and is retrying; `:skipped` means no schema matched, the schema was invalid
  or unreadable, doc automation was disabled, or no trigger matched, so the
  commit is code-only. A node pushed before its docs resolved keeps the
  `docs_state` it was pushed with; the project page then also links the docs
  child node, so the snapshot's badge never claims docs its immutable tree does
  not contain. A server-created meld node is recorded `:pending` at approval
  (§6.5) even though no daemon-side job exists for it; §16 tracks that gap.
- Web approve/reject for pending docs is deferred: nodes are immutable, so
  "reject" needs a review object that does not exist yet. Recorded in §16.
- Reverting docs does not revert code — they're separate commits under one
  logical node.

### 9.5 Offline

If offline, commit with `docs_state: :pending`. On reconnect, run the agent and
amend the docs into a follow-up commit. If the job resolves before the node is
pushed, the server receives one node pointing at `C2`; if it defers, the
code-only `C1` node syncs and the docs are retried later (and attach as a child
node if the code snapshot is already on the server).

A node with a **queued** doc job — automatic or manual — is held out of the
push queue until the job resolves to `:current` (docs committed as `C2`) or is
deferred, so its `git_commit_sha` can move from `C1` to `C2` before the server
ever sees it. A **deferred** job is pushed at `C1` code-only — docs never block
sync — and is retried on reconnect or `:CadDocSync`. The reconnect retry runs
*before* the pass pushes, on the first pass after an outage (or at boot): a
successful retry therefore still reaches the server as one node at `C2`, while a
retry that fails again releases its hold and the node is pushed at `C1` on the
next pass. The retry is not repeated on every pass, so a permanently failing
job cannot hold a node out of sync. Boot/reconnect retries resume local nodes
with a `SyncPending` row and pushed nodes whose docs are still deferred (their
docs become a child node); a pulled node with neither is never regenerated
locally. A *successful* pass does not request the retry, so deferred docs on an
already-pushed node are picked up at the next boot, the next failed-pass
recovery, or `:CadDocSync`.

**Already-pushed fallback (child node).** A node whose current SHA is on the
server is immutable and is never rewritten. If its docs resolve afterwards — a
push lands while the model runs, a manual `:CadDocSync` targets a code-only
pushed node, or a reconnect retry resumes a stamped pushed node whose docs were
deferred — the job writes `C2` (git parent `C1`) and inserts it as a **docs
child node** instead:

- `git_commit_sha: C2`, `parents: [code_node.id]`, `docs_state: :current`,
  `flags: [:"in-progress"]`, `pinned: false`
- `session_metadata["docs"]["docs_for"] = code_node.id`, plus
  `code_commit_sha`, `docs_commit_sha`, `model`, `provider`,
  `prompt_version`, `paths`, `generated_at`
- the child gets its own `SyncPending` row in the insert transaction and is
  queued for sync, so the server receives it as a descendant of the code commit
  it already has; the pushed parent is neither re-held nor re-queued
- the parent records the result locally (`docs_state: :current`,
  `docs_commit_sha: C2`, `docs_child_id`) without changing its SHA, so
  `:CadDocDiff` and `DocDiff.build/2` work for both nodes
- the session pointer advances to the child **only if** it still points at the
  code node, so a background job never yanks the user off another node; the
  child's tree matches the docs written into the working tree, so the watcher's
  unchanged-tree guard absorbs a late event

A repeat job for the same code node reuses the recorded `docs_child_id` instead
of creating a second child, and an empty generation (no operations) creates no
child at all: the parent is recorded `:current` with `"empty": true` and its SHA
is untouched.

A pushed node keeps the `docs_state` it was pushed with on the server (its
snapshot is immutable); the docs child carries the `:current` state for the
generation that happened after the push.


### 9.6 Worker design

Doc generation runs outside the commit pipeline. A per-daemon `DocQueue`
(GenServer) owns the job list and delegates each job to `DocAgentWorker` under a
`Task.Supervisor`. The agent call is isolated because it is the most
API-cost-heavy component: a slow or failing model never blocks a commit, the
watcher, or sync.

- One `Hammer` limiter (key `:docs`) is shared across the daemon; the meld
  limiter is separate and server-side.
- The LLM client is injectable (`:docs_llm`) for tests; no test hits a real
  provider.
- `CAD_DOCS_TIMEOUT_MS` bounds one call. `CAD_DOCS_RETRY_ATTEMPTS` and
  `CAD_DOCS_RETRY_BACKOFF_MS` bound retries with linear backoff; a raising job
  is rescued and recorded as deferred rather than stranding the node.
- Terminal job errors are `:not_configured`, `:missing_code_commit`,
  `:no_location`, `:too_many_docs`, `:context_too_large`, and `:pushed`. They
  stop retrying and leave the docs deferred (`docs_state: :pending`,
  `metadata["docs"]["state"] = "deferred"`) so a local node can sync code-only.
  A manual preflight skip marks code-only outcomes (`:disabled`, `:no_schema`,
  `:legacy`) as `:skipped` and defers `:invalid_schema`, `:not_configured`, and
  `:no_location`. Everything else retries with backoff until
  `CAD_DOCS_RETRY_ATTEMPTS`, then defers.
- The prompt template lives in `priv/prompts/docs.txt` (plain text, versioned);
  every result records `provider`, `model`, and `prompt_version` in
  `session_metadata["docs"]`.
- `CAD_DOCS_MAX_OPS`, `CAD_DOCS_MAX_FILES`, `CAD_DOCS_MAX_FILE_BYTES`,
  `CAD_DOCS_CONTEXT_BYTES`, and `CAD_DOCS_DIFF_MAX_BYTES` cap cost and prompt
  size; unlisted or over-budget docs are read-only to the agent.

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
- Node snapshots are immutable, but `pinned` is server-authoritative and
  mutable. A pin/unpin bumps that node's `nodes.seq` **after** the pin commits
  (a `nextval` allocated inside a transaction is not visible until commit, so
  an earlier bump could sit below a cursor a concurrent pull already advanced
  past). The next pull redelivers the row; the daemon applies **only** `pinned`
  to an existing node (same id, commit, parents) and treats any other
  difference as a conflict. A failed cursor bump is logged and the pin stands;
  redelivery then waits for the next change or poll.

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
pushes, every proposal decision, and every server-side pin change, fanning out
to **every project member's** user topic (daemons only join their own); an
accepted preference write notifies the acting user. Daemons connect to
`/socket/websocket`, authenticate with an `x-cadence-token` header (never a
query parameter), and join `sync:user:<server_user_id>`. The channel is a
**latency accelerator only**: it carries a `sync_available` hint with
`%{project_id}`, never DAG or preference state, and polling remains the
correctness fallback. `CAD_SYNC_CHANNEL_ENABLED=false` disables the socket
without disabling sync.

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
  project_id, parent_node_ids: [uuid]   # 2..8 distinct parents
  # Routed at POST /sync/union (4d-2): delegates to
  # Cadence.Server.Melds.propose/3 synchronously. Members with can_propose?
  # (owner or trusted) only. A pending meld for the same ordered parents is
  # returned instead of running a duplicate union.

SyncMessage.UnionResponse
  proposal_id, proposal_token, status, kind
  # Union creates a *proposal*, not a node. The meld node is created only if
  # the proposal is approved. 201 on success; 403 not a proposer, 404 unknown
  # project, 422 invalid/too many parents or payload, 429 meld rate limited
  # (with Retry-After), 502 meld/model failure, 500 server object corruption.
  # The synchronous call can take up to
  # (CAD_MELD_RETRY_ATTEMPTS + 1) × CAD_MELD_TIMEOUT_MS + CAD_MELD_RETRY_BACKOFF_MS
  # (about 120.5 s at defaults); callers must budget above that.
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
| Demo password hashing (compile-gated, demo builds only) | `bcrypt_elixir` |
| Ash data layer | `ash_postgres` |
| Phoenix auth routes | `ash_authentication_phoenix` |
| Ash DSL formatting / codegen | `sourceror` (dev/test only) |
| LiveView test DOM | `lazy_html` (test only; required by `Phoenix.LiveViewTest`) |
| Docker API | `ex_docker_api` |
| Rate limiting | `Hammer` (declared in `cadence_shared`; used by the daemon's `LLMRateLimit` and the server's `LLMRateLimit` / `MeldWorker`) |
| Graph model | `libgraph` |
| TUI (optional, daemon-side) | `ExRatatui` |
| Neovim plugin | Lua + plenary.nvim |
| HTTP client (daemon → cloud) | `Req` |
| Notification channel (daemon → server) | Phoenix Channels + `slipstream` |
| ORM / schemas | Ecto (`ecto`, `ecto_sql`) |
| JSON codec | `Jason` |
| Docs schema parsing (`.caddocs.yaml`, §9.1) | `yaml_elixir` (declared in `cadence_shared`; `yamerl` is its parser) |
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

The repository also ships a **local demo stack** (`docker-compose.yml` +
`docker/Dockerfile.demo`): `postgres:16-alpine` plus a `MIX_ENV=dev` server that
runs migrations, seeds demo data (`mix cadence.demo_seed`), and boots only
`cadence_server` (no daemon). CSS is bind-mounted for style iteration and the
demo password strategy is compiled in via `CAD_DEMO_AUTH` (§7.4). This is an
exploration aid, not a production artifact; the release path in §12.8 remains
authoritative. See `docs/demo.md`.

### 12.5 Configuration strategy

**Rule: everything configurable is an environment variable, read at runtime
via `config/runtime.exs`.** No build-time config for anything that might
change between deployments.

The single deliberate exception is `CAD_DEMO_AUTH` (§7.4): it must be fixed at
compile time so a production build physically cannot contain the demo password
strategy. `runtime.exs` still validates the runtime value and refuses to boot a
prod release with it set.

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

  config :cadence_server,
    actions_enabled: System.get_env("CAD_ACTIONS_ENABLED", "true") == "true",
    docker_socket: System.get_env("CAD_DOCKER_SOCKET", "http://localhost:2375"),
    artifact_path: System.get_env("CAD_ARTIFACT_PATH", "/data/artifacts")
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
| `CAD_PROPOSAL_MAX_FILES` | no | `200` | Max changed files listed on a public proposal page |
| `CAD_SCAN_MAX_FILES` | no | `10000` | Max files scanned for secret quarantine |
| `CAD_SCAN_MAX_BYTES` | no | `16777216` | Max snapshot bytes scanned for secret quarantine |
| `CAD_MELD_TIMEOUT_MS` | no | `60000` | Timeout per meld agent attempt (a synchronous union can take `(retries + 1) × timeout + backoff`) |
| `CAD_MELD_RATE_LIMIT` | no | `5` | Meld agent calls per server rate window |
| `CAD_MELD_RATE_SCALE` | no | `60000` | Meld rate window in milliseconds |
| `CAD_MELD_MAX_OPS` | no | `50` | Max file operations accepted from the agent |
| `CAD_MELD_MAX_FILE_BYTES` | no | `262144` | Max bytes per agent-written file |
| `CAD_MELD_CONTEXT_BYTES` | no | `65536` | Max rendered parent/conflict context in the meld prompt |
| `CAD_MELD_RETRY_ATTEMPTS` | no | `1` | Retries after a transient meld provider error |
| `CAD_MELD_RETRY_BACKOFF_MS` | no | `500` | Delay between meld retries |
| `CAD_ARTIFACT_PATH` | no | `/data/artifacts` | Action outputs |
| `CAD_ACTIONS_MAX_MANIFEST_BYTES` | no | `32768` | Max `actions/manifest.json` bytes read from a node snapshot |
| `CAD_ACTIONS_MAX_ACTIONS` | no | `20` | Max actions accepted from one manifest |
| `CAD_OAUTH_GITHUB_CLIENT_ID` | no | — | GitHub OAuth |
| `CAD_OAUTH_GITHUB_CLIENT_SECRET` | no | — | GitHub OAuth |
| `CAD_OAUTH_GOOGLE_CLIENT_ID` | no | — | Google OAuth |
| `CAD_OAUTH_GOOGLE_CLIENT_SECRET` | no | — | Google OAuth |
| `CAD_DEMO_AUTH` | no | `false` | **Build-time** switch for the demo password strategy (§7.4); must be absent in prod |
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
| `CAD_SYNC_UNION_TIMEOUT_MS` | no | `180000` | Synchronous union HTTP timeout (must exceed the server's `(CAD_MELD_RETRY_ATTEMPTS + 1) × CAD_MELD_TIMEOUT_MS + CAD_MELD_RETRY_BACKOFF_MS`) |
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
| `CAD_DOCS_ENABLED` | no | `true` | Master switch for documentation automation, including manual `:CadDocSync` (§9) |
| `CAD_DOCS_TIMEOUT_MS` | no | `30000` | Max LLM call time per doc job |
| `CAD_DOCS_RATE_LIMIT` | no | `5` | Doc agent calls per daemon rate window |
| `CAD_DOCS_RATE_SCALE` | no | `60000` | Doc rate window in milliseconds |
| `CAD_DOCS_RETRY_ATTEMPTS` | no | `3` | Retries before a deferred doc job drops to `:pending` |
| `CAD_DOCS_RETRY_BACKOFF_MS` | no | `5000` | Linear retry backoff unit for doc jobs |
| `CAD_DOCS_MAX_OPS` | no | `20` | Max file operations accepted from the doc agent |
| `CAD_DOCS_MAX_FILES` | no | `200` | Max files under `docs_dir` read for one doc job |
| `CAD_DOCS_MAX_FILE_BYTES` | no | `262144` | Max bytes per agent-written doc file |
| `CAD_DOCS_CONTEXT_BYTES` | no | `65536` | Max rendered schema/docs context in the doc prompt |
| `CAD_DOCS_DIFF_MAX_BYTES` | no | `32768` | Max diff text sent to the doc agent |

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
- 4a — Proposal model/API: pending meld/promotion lifecycle (`meld`,
  `promotion`, nullable `target_node_id`), precomputed meld result tree/commit,
  single approver, idempotent state transitions.
- 4a-1 — Server-only `Proposal` and `Incident` schemas/contexts; critical open
  incidents block approval. No UI or worker.
- 4a-2 — Public read-only proposal token/URL with §7.6 filtering/quarantine;
  auth-gated actions.
- 4b — Server-side meld worker: permission checks, parent tree fetch, AI meld
  prompt, resulting tree/commit, validation guard (no auto-`functioning`);
  auto-open incidents on secret/scan/meld failures.
- 4b-2 — Server push scan: scan imported node snapshots, open node incidents,
  and enforce persisted isolation.
- 4c — Review UI: member review hub (proposal list + detail), file-level result
  and integrity state, approve/reject with a verified result and node
  attach/pin, open-incident panel with re-scan/acknowledge resolution,
  shareable link, server-side authorization on every event.
- 4d — Broadcast/pull convergence + union trigger: approved melds and pin
  changes reach connected daemons (`sync_available` fan-out, post-commit cursor
  bumps); routed `POST /sync/union` creates a proposal through
  `Melds.propose/3` and returns its token; daemon/Neovim submit the union
  picker.
- 4e — UI styling & freshness: the review hub/detail subscribe to the project
  topic after connect (creation, decision, and incident events; membership
  re-read per event) and the public project page refreshes only a selected
  node's quarantine on incident events. Shared presentation helpers plus
  severity/status/file badges, callouts, button modifiers, and an incident
  panel above the queue with an open count and wrapped details (§6.6, §6.7,
  §7.2). Live DAG re-layout on `nodes_pushed` stays deferred.
- Proposal UI must not ship before 4a/4b exist; AI output stays reviewable and
  reversible. The deterministic scanner, not the LLM, decides safety.

**Phase 5 — Doc automation (week 16)**
- 5a — shared primitives: `.caddocs.yaml` schema parse/validation, pure glob
  matching, trigger gating (`generated_from`, schema change, API-surface
  heuristic), the docs prompt plus a strict MODIFY/CREATE parser with
  read-only-path protection, `UTF8`, and a path-directed
  `GitStore.merge_files/3` (§9.1, §9.3, §11).
- 5b — daemon worker: `SchemaSource` caches `.caddocs.yaml` on the project row;
  `CommitQueue` evaluates the trigger and sets `docs_state`;
  `DocQueue`/`DocAgentWorker` generate `C2`, write the working tree
  (schema-scoped, watcher-suspended, divergence-guarded), and defer with a
  shape-only error; `SyncLedger` holds a queued node out of push; boot and
  reconnect retries resume deferred nodes (§9.5, §9.6, §12.6).
- 5c — daemon API + Neovim: `POST /docs/sync` (`202` queued / `200` skipped /
  `503` / `404` / `422`) and `GET /docs/diff` (`200` / `404` / `409` / `400`),
  `:CadDocSync`, and `:CadDocDiff` (§9.4).
- P4 — deferred/pushed docs: the reconnect retry runs before the pass pushes;
  an already-pushed node's docs attach as a child node; the project page shows a
  read-only `docs_state` badge and links the docs child (§9.4, §9.5).

**Phase 6 — Docker actions (week 17+)**
- 6a — manifest foundation: strict parse/validation of `actions/manifest.json`
  from a node snapshot, caps, `CAD_ACTIONS_ENABLED`, members see / managers run,
  and a read-only action list on the project page (§8, §12.6).
- 6b — runner: `ex_docker_api` integration (spec §11 version row), snapshot
  staging into a shared volume, image reuse/build cache, container
  create/start with no network by default plus CPU/memory limits, log capture,
  artifacts, and the sandboxed-compose socket proxy (§8.3, §8.4, §12.4).
- 6c — web run experience: run buttons, streamed output over PubSub/LiveView,
  artifact links, and the `expose` visibility decision (§16 if still open).

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
- [x] **Pin propagation to daemons:** resolved in 4d-1 — a pin/unpin bumps
      the node's `nodes.seq` after the update commits, and the daemon applies
      only `pinned` to an existing node on pull (§10.3, §10.5). A pin change
      also wakes every member's daemon via `sync_available`. If the cursor bump
      itself fails, the change is not redelivered until the next change/poll;
      the pin is still committed.
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
      concrete need appears; adding them later requires a migration. Public
      proposal links must respect project visibility once it exists.
- [x] **Review/promotion UI placement:** resolved in 4c/4e — the review hub and
      detail page ship with approve/reject, integrity and isolation state, and
      the incident panel above the queue (§7.2). Live DAG refresh on
      `nodes_pushed` remains deferred: `DAGLayout.layout/2` recomputes intro
      timing, so a live refresh would replay the animation and disturb the
      selected pane.
- [x] **Doc agent model:** resolved for Phase 5 — the doc agent uses the
      configured `CAD_LLM_*` client through `Cadence.Shared.LLM`; per-project
      model overrides remain deferred.
- [ ] **Web docs review (approve/reject):** deferred from Phase 5. Nodes are
      immutable, so rejecting generated docs needs a review object (like a
      proposal) rather than mutating the node. Until then the web UI shows a
      read-only `docs_state` badge (linking the docs child node when the
      generation happened after the snapshot was pushed), and review happens in
      Neovim via `:CadDocDiff` (§9.4).
- [ ] **Docs for server-created meld nodes:** an approved meld node is inserted
      with `docs_state: :pending` (§6.5), but doc generation requires local
      provenance (a `SyncPending` row or a pushed-SHA stamp) and a pulled node
      is `:legacy`, so no daemon job will ever move that node to `:current`.
      Decide whether approval should record `:skipped` instead, or whether an
      explicit daemon action may generate docs for a pulled node (which would
      need its own review/revert path). Until then the badge shows the
      approval-time state (§9.4).
- [ ] **Local store:** SQLite via `ecto_sqlite3` is the obvious pick; confirm
      it fits the daemon's needs.
- [ ] **Neovim plugin distribution:** plain Lua files, or a proper plugin with
      lazy.nvim/packer specs.
- [ ] **Docker-in-Docker vs. host socket proxy:** host socket proxy is the
      current plan (§8.4). Revisit if isolation needs increase.
- [ ] **Action `expose` semantics (Phase 6c):** `actions/manifest.json` carries
      `expose`, but 6a parses it without honoring it. Decide whether
      `expose: true` publishes the action to anonymous visitors (listing only;
      execution stays owner/trusted) or whether the whole panel remains
      members-only. Until then members see all actions and anonymous visitors
      see none. The manifest file itself is ordinary repository content
      (browsable per §7.5) and is not confidential.
- [ ] **`Project.actions_manifest` is unused:** the data model still has the
      column (§4.2), but 6a reads the manifest from the selected node snapshot.
      Repurpose it as a cache or remove it in a schema slice so the model and
      the implementation agree.
- [ ] **Public preview auth:** fully anonymous, or require a lightweight
      signed-URL / API key to avoid scraping.
- [ ] **Backup strategy for the cloud server:** Postgres WAL archiving +
      object store for Git packfiles.
- [ ] **Multi-user conflict UX:** when two trusted users spawn from the same
      node, how does the picker display the divergence?
- [x] **Promotion target:** resolved for Phase 4 — approval sets `pinned`.
      `functioning` remains validator-owned and is never set by approval (§6.6).
- [x] **Proposal model:** resolved for Phase 4 — a single approver (owner, or
      trusted with the per-project `approver` grant) decides. Terminal states
      are immutable; a rejected proposal may be re-submitted as a new proposal.
- [x] **Proposal visibility:** resolved for Phase 4 — proposal links are public
      read-only by default, subject to §7.6 filtering/quarantine. Approve,
      reject, and resolve require authentication and project roles. Proposal
      content has no raw-view bypass.
- [x] **Meld flag validation:** resolved for Phase 4 — an AI meld is
      `in-progress`; approval promotes/pins the line. Never auto-promote to
      `functioning` until a real validator exists (§6.6, §6.7).
- [ ] **Team/supervisor schema:** exact shape and sync channel for the
      lightweight §4.6 relationships.
- [x] **Proposal link format:** resolved for Phase 4 — a stable high-entropy
      URL-safe token renders the parents, result diff/tree (filtered), flags,
      status, and timestamps. Reviewer/proposer identities are not exposed to
      anonymous visitors. Mutations are auth-gated.
- [ ] **Incident planning integrations:** Phase 4 ships alerts with
      `open | resolved` only. Assignee, comments/threads, and external issue
      tracker integrations are deferred (§6.7).
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
