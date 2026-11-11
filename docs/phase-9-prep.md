# Phase 9 — Import an existing Git repository

**Spec:** §4.1 (nodes), §5.1/§5.3 (daemon, commit pipeline), §6 (DAG), §7.3
(web DAG), §10.1/§10.2 (push protocol), §12.6 (env contract), §13 (build
order), §16 (open decisions).
**Status:** approved 2026-11-11 (recommended defaults D1–D10); **9a and 9b
shipped 2026-11-11**; 9c–9e pending, no web/server-side import yet.
**Dependencies:** none new. `GitStore` already reads loose objects and packs.

## Goal

A user points the daemon at a normal local Git repository (`~/code/thing`,
bare or with a worktree) and Cadence imports its history as a project DAG:
one node per commit, original SHAs and messages, parents preserved (including
merges), then publishes it to the configured server so it is browsable at
`/p/:slug`. The imported tip becomes the session pointer, so further edits in
the same working tree continue the Cadence history.

## Verified starting state

- `GitStore` keeps **no refs, HEAD, or work-tree metadata** by design
  (`git_store.ex:53`), and `open/2` assumes `<path>/.git` is a directory
  (`git_store.ex:73-78`). There is no `read_ref`, commit walk, tag peel,
  shallow detection, or `.git`-file resolution.
- `GitStore.objects_from/2` walks a commit's tree/blobs but **not its parent
  commits** (`git_store.ex:579-600`). Packed-object reads already work (7a), so
  a foreign repo's packs are readable.
- `read_commit/2` already decodes `tree`, `parent`, `author`/`committer`
  identities with timestamps and timezones (`git_store.ex:1356-1381`).
- Daemon: `Projects.register_project/1` creates the project, location, owner
  membership, and the `{CommitQueue, Watcher}` pair. `SyncLedger.insert_pending!/1`
  and `Sync.push_pending/1` exist; enqueueing wakes `SyncWorker`
  (`sync_ledger.ex:54`, `sync.ex:166`).
- Server refuses a pushed node with more than one parent: `@max_parents 1`
  (`server/sync.ex:21,310`) and `check_parents/2` validates only the single
  parent (`sync.ex:413-418`). The DAG schema already supports arrays.
- The endpoint's `Plug.Parsers` uses Plug's default body limit (8 MB,
  `endpoint.ex:55-59`); a node payload with large objects can 413.
- The web DAG renders **every** node (`Portfolio.list_nodes/1`,
  `DAGLayout.layout/2`, `ProjectLive`); a 1,000-commit history would be a
  40,000-pixel SVG with 1,000 links and tooltips.
- `Project.docs_state` must be one of `current | pending | skipped`; imported
  nodes have no local docs provenance.

## Mapping: Git commit → Cadence node

| Node field | Value |
|---|---|
| `git_commit_sha` | the original 40-hex commit SHA (objects copied byte-identically; never rewritten) |
| `parents` | node UUIDs of the commit's parents, in order; a root commit is `[]`, a merge has N (see D1) |
| `flags` | `[]` — flagless renders as the muted `flag-unknown` dot; an import never claims `functioning` |
| `pinned` | `true` for the selected ref's tip, so the public preview is deterministic |
| `message` | the full commit message (subject + body); display code keeps its existing clamping |
| `created_at` | the commit's **author** timestamp, falling back to the committer timestamp |
| `created_by` | the importing local user (the server maps it to the pushing user) |
| `docs_state` | `:skipped` (no local session can generate docs for historical commits) |
| `session_metadata["import"]` | `%{"source" => "git", "refs" => [...], "author" => name, "author_email" => email, "imported_at" => ...}`; the public UI never renders the email |
| session pointer | moved to the tip node after the import |

The imported project's **preview** is the pinned tip; older commits are
reachable from the DAG/repository browser.

## Pipeline

1. **Validate the source.** `Path.expand`, require a directory, detect
   worktree (`.git` dir), worktree redirect (`.git` file with `gitdir:`), or
   bare repo (`HEAD` + `objects/`). Reject anything else with a typed error.
2. **Resolve refs.** `HEAD` by default; `--ref` repeatable
   (branch/tag/40-hex); `--all-refs` for local branches and tags. Annotated tags
   are peeled to their commit. Record the selected refs in the metadata.
3. **Walk commits.** Parents-first reverse topological order, with a visited
   set, a commit cap, and missing-parent detection (shallow clone or alternates).
4. **Copy objects.** Copy each commit object and its tree/blobs into the
   project's store with a global visited-tree set. Existing objects are skipped
   (content-addressed). Every copied object is re-verified against its SHA by
   `import_objects/2` before it is written.
5. **Insert nodes.** Batched transactions (e.g. 100). Each node gets a
   `SyncPending` row in the same transaction (parents-first invariant). Build a
   `SHA → node UUID` map as batches commit; parents always precede children, so
   the map is complete when needed.
6. **Pin + point.** Pin the tip, move the session pointer to it, and resume the
   watcher. If the working tree differs from the imported tip, commit it once
   with `skip_unchanged: true` (an edit made during the import is never lost).
7. **Publish.** Wake sync; a background drain pushes the queued nodes in
   parents-first batches. Publication is best-effort/offline-tolerant exactly
   like normal commits; the journal and ledger hold the work.

## Decisions needing approval

| # | Decision | Recommendation |
|---|---|---|
| D1 | **Merge topology.** Preserve multi-parent commits in Cadence (needs a server push exception), or import the first-parent chain only? | **Approved: preserve.** Allow a pushed node up to `CAD_SYNC_MAX_PUSH_PARENTS` (default 8) parents **only** when it carries `session_metadata["import"]["source"] == "git"` and the caller is the project **owner**; normal pushes stay at 1. Spec §10.2 records the exception. First-parent-only would silently lose merged branches. |
| D2 | **Scale.** Import all commits, or cap? And how does the DAG render a large history? | **Approved: import up to `CAD_IMPORT_MAX_COMMITS` (default 2,000); render only the newest `CAD_DAG_MAX_NODES` (default 150) in the DAG**, with "Showing the newest 150 of N commits" and a paged `History` list for the rest. Disable the intro animation above `CAD_DAG_INTRO_MAX_NODES` (default 60). This keeps the full tree in data without an unusable page. |
| D3 | **Which refs.** | **Approved:** `HEAD` by default; `--ref` repeatable; `--all-refs` for branches + tags. Tags peel to commits. |
| D4 | **Publication.** | **Approved:** import locally, queue sync rows, and drain in the background. If the server is unconfigured or unreachable, the import still succeeds and publishes on the next successful pass. |
| D5 | **Large objects.** | **Approved:** preflight `CAD_IMPORT_MAX_BLOB_BYTES` (default 8 MiB) and a per-node payload estimate; reject with the offending paths rather than touching the store. Raise the `/sync` body limit with a **sync-scoped parser** (`CAD_SYNC_MAX_BODY_BYTES`, default 64 MiB) so a node whose whole tree is moderately large can still push. Blobs above the limit are a documented limitation (use LFS/filter-repo in the source repo); we do not rewrite history. |
| D6 | **Existing projects.** | **Approved:** v1 imports into an **empty** Cadence project only; importing again into the same project is idempotent by `(project_id, git_commit_sha)` and adds missing commits. A project with non-imported nodes is refused unless the user creates a new project. |
| D7 | **Flags.** | **Approved:** imported nodes are **flagless**; do not add an `:imported` flag (that would need spec §3.1 and every UI palette). Provenance lives in `session_metadata` and a node-pane line. |
| D8 | **Job model.** | **Approved:** a supervised `Cadence.Daemon.Importer` with one job at a time (like `Storage.Repacker`): `POST /import` returns `202` + job id, `GET /import/:id` reports `running | completed | failed` with progress counts. `mix cad.import` polls; the release gets `Cadence.Daemon.Release.import/…`. No new table. |
| D9 | **Secrets in history.** | **Approved:** never bypass the scan. Historical secrets are exactly why the scan exists: the server will quarantine those snapshots and open incidents. The import report includes `quarantined`/`incidents` counts, and the docs warn before importing a repo with old credentials. |
| D10 | **Provenance UI.** | **Approved:** show `Imported from git · <author name>` in the node pane (email only to managers, per §7.2); no changes to the public tooltip beyond the existing message/flags. |

## Slices

### 9a — shared Git import primitives (shipped 2026-11-11)

- `GitStore.detect_repository/1` (worktree `.git` directory, `.git` redirect
  file, bare) and `repository()` type.
- `GitStore.read_ref/2` (HEAD symbolic/detached, loose refs, `packed-refs`,
  loose-wins, traversal guard) and `GitStore.resolve_revision/2` (branch, tag,
  HEAD, 40-hex; annotated tags peeled through `:tag` objects).
- `GitStore.shallow_commits/1` and `GitStore.walk_commits/3`: bounded BFS,
  parents-first Kahn order (deterministic by author timestamp then SHA),
  `:max` + `:truncate`, shallow boundaries as roots, missing objects as typed
  errors.
- `GitStore.copy_commit_objects/4`: copies commits and their tree/blob closure
  with a shared-tree visited set, re-hashes every written object, skips
  gitlinks, and enforces `:max_blob_bytes`.
- Git tag objects are now readable from loose files and packs (pack type 4);
  `write_raw/3` accepts `:tag` (used by the fixture writer).
- The tree decoder marks gitlink entries (mode `160000`) as `:commit` instead
  of `:blob`. `objects_from/2`, `walk_blobs/3`, and the secret scan skip them;
  `read_path/4` returns `:not_a_file`; the repository browser renders a
  non-clickable `submodule` row (`repo.ex`).
- Tests: `apps/cadence_shared/test/git_import_test.exs` covers detection,
  refs, tags, merges, shallow boundaries, the cap/truncate behavior, object
  copy/idempotency, the blob limit, and the gitlink skip;
  `apps/cadence_server/test/repo_component_test.exs` covers the submodule row.
- Not followed: `objects/info/alternates` (a missing object is a named error),
  and annotated tags are read but not copied into the destination store (only
  their commit is imported).

### 9b — daemon importer, API, CLI (shipped 2026-11-11)

Shipped as `Cadence.Daemon.Importer` (+ `ImportTasks`), `POST /import`,
`GET /import/:id`, `mix cad.import`, `Cadence.Daemon.Release.import/2,3`, and
`Cadence.Daemon.ImportClient`. Shared additions: `GitStore.list_refs/1`,
`resolve_revision/2` accepting full `refs/...` names, and
`GitStore.preflight_blobs/3` (blob cap + per-node estimate).

- `Cadence.Daemon.Importer`: validation, refs, walk, copy, batched node insert
  with sync rows, pin/pointer, dirty-tree commit, job state, progress, typed
  errors. Suspend the watcher for the insert phase and resume after.
- `POST /import` (202 + job id), `GET /import/:id`; validation errors map to
  400/404/409/422/429/503.
- `mix cad.import PATH [--name] [--slug] [--ref] [--all-refs] [--allow-shallow]
  [--limit N]` (source checkout) and a `Cadence.Daemon.Release.import/…` helper.
- Config: `CAD_IMPORT_MAX_COMMITS`, `CAD_IMPORT_MAX_BLOB_BYTES`,
  `CAD_IMPORT_MAX_SECONDS`, `CAD_IMPORT_ALLOW_SHALLOW`, `CAD_IMPORT_PUSH_BATCH`.
- Tests: linear, root, merge, tag, idempotent re-run, non-empty project, shallow
  reject/allow, large blob preflight, dirty tree, job status, socket/mix paths.

### 9c — server protocol for imported merges

- `@max_parents` becomes a policy: 1 for ordinary pushes; up to
  `CAD_SYNC_MAX_PUSH_PARENTS` for owner-pushed nodes carrying the import
  marker. `check_parents/2` validates every parent and the project scope.
- Sync-scoped `Plug.Parsers` with `CAD_SYNC_MAX_BODY_BYTES` (default 64 MiB);
  the browser/public pipeline keeps the default. Tests for 413 and the limit.
- Spec §10.2 records the exception; `docs/progress.md` notes the governance
  trade (no review gate for imported merge nodes).

### 9d — web scale and provenance

- `Portfolio.list_nodes/2` with `:limit`/`:offset`; the project page renders
  the newest `CAD_DAG_MAX_NODES` and shows the count/truncation note.
- New public `History` list (paged 50: message, author display name, date, short
  SHA, link to the node) for the remainder; selecting an old commit opens its
  snapshot in the existing pane.
- Intro animation skipped above `CAD_DAG_INTRO_MAX_NODES`.
- Node pane provenance line; author emails only to `can_manage?` audiences.
- Tests: cap boundary, truncation note, history paging, intro threshold,
  provenance visibility, redacted messages for anonymous viewers.

### 9e — docs, spec, smoke

- `docs/import.md`: prerequisites, command/API, caps, shallow/LFS/submodule/
  alternates limitations, secrets warning, offline publication, upgrade path.
- Spec: new §5.7 "Importing an existing repository", §7.3 render cap, §10.2
  multi-parent exception, §12.6 new keys, §13 Phase 9, §16 decisions
  (merge topology, large blobs, history browsing).
- Live smoke: generate a fixture repo (GitStore + refs files, ~50 commits with
  a merge and a tag), import it, publish to the demo stack, verify identical
  SHAs/parents on both sides, the public pages, the capped DAG + history list,
  and a secret-bearing commit being quarantined.

## Acceptance

- A fixture with N commits, one merge, and one tag produces exactly N nodes,
  original SHAs/messages/author dates, a root with no parents, the merge with
  two, all flagless, `docs_state: :skipped`, the tip pinned, and the pointer at
  the tip.
- Re-running the same import adds nothing.
- The published server graph has the same SHAs and parents; `/p/:slug` renders
  the newest `CAD_DAG_MAX_NODES` and the history pages the rest;
  `/p/:slug/n/:node_id` opens an imported commit.
- Exceeding a cap or hitting a shallow/large-blob/alternates case returns a
  typed error and leaves no partial project (batched transactions are
  resumable, and a failed batch rolls back).
- A historical secret is quarantined and reported; the import never bypasses
  the scan.
- Full gate (format, dev+prod compile, tests) and the live smoke pass.

## Risks

1. **Protocol/governance:** allowing owner-pushed multi-parent nodes bypasses
   the meld review path for imports. Mitigation: owner-only + marker + cap;
   documented in §10.2/§16. A stricter option is to add an import proposal type
   later; that is a bigger feature.
2. **Scale:** 2,000 nodes × ~50 objects is ~100k loose objects in the daemon
   store; inserts, sync rows, and server scans take time. Batched inserts,
   background push, and explicit progress keep it bounded; the server scan runs
   per pushed node and may be the slowest part.
3. **Large objects / body limits:** raising the sync body limit is a memory/DoS
   trade; a sync-scoped parser and a per-blob preflight keep it explicit.
4. **History UX:** the newest-N cap can cut a branch. The history list is the
   escape hatch; a date-based cap is intentional and recorded.
5. **Source edge cases:** shallow clones, alternates, LFS pointers, submodule
   gitlinks, and `.git` worktree redirects are detected and either handled or
   refused with a named error. They are not silently mis-imported.
6. **Import while editing:** the watcher is suspended for the insert phase and
   a dirty tree is committed once against the imported tip, so no edit is lost
   and no commit interleaves with the import.
