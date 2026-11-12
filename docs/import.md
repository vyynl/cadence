# Importing an existing Git repository

Cadence can adopt a normal local Git repository and turn its history into a
project DAG: one node per commit, with the original commit SHA, message, author
timestamp, and parents (merges included). The import is read-only on the source
repository and never rewrites history — Cadence copies the existing Git objects
byte-for-byte into its own store.

The normative contract is spec §5.7 (pipeline) with §7.3 (web rendering),
§10.2 (multi-parent push), and §12.6 (the environment keys). This guide is the
operator/developer walkthrough.

- Local daemon setup (token, env file, first boot): `daemon-setup.md`
- A browsable server without OAuth: `demo.md`
- The product/technical contract: `spec.md`

## 1. What an import is, and is not

An import is a **one-way snapshot of existing commits**. It does not:

- create a proposal, meld, or review — an owner pushes imported merges directly
  under the §10.2 exception;
- generate documentation for historical commits (nodes are
  `docs_state: :skipped`);
- assign flags (imported nodes are flagless; Cadence never claims a historical
  commit is `functioning`);
- fetch LFS content, clone submodules, or follow `objects/info/alternates`;
- rewrite or normalize anything. SHAs and parent order are preserved.

After the import, the source repository keeps working normally. If it is a
working tree, further edits in that directory continue the Cadence history from
the imported tip, exactly like a registered project.

There is no web-side "import" button: the daemon owns the source path, so the
entry points are `mix cad.import` (source checkout or any machine that can reach
the daemon socket) and the daemon's Unix-socket API (`POST /import`).

## 2. Prerequisites

1. **A running daemon** with its SQLite database migrated
   (`mix ecto.migrate -r Cadence.Daemon.Repo`, or
   `Cadence.Daemon.Release.migrate/0` for a release). See `daemon-setup.md` §6.
2. **A readable source repository.** Any of:
   - a worktree with a `.git` directory,
   - a worktree whose `.git` is a redirect file (a linked worktree or
     submodule-style checkout: `gitdir: …`),
   - a bare repository (`HEAD` + `objects/`).

   The daemon must run as a user that can read the objects. Loose objects and
   packs both work; an object it cannot decode is a typed error, not a crash.
3. **Disk headroom.** Imported objects are copied into the daemon's store
   (`CAD_STATE_DIR/git/<project_id>`); budget roughly the source's object size
   (shared subtrees are copied once per project).
4. **A server and token only if you want publication now.** Without
   `CAD_SERVER_URL`/`CAD_AUTH_TOKEN` the import still succeeds offline and the
   sync ledger holds the nodes until a later successful pass. See §8.
5. **The source must be within the caps** in §5 (`CAD_IMPORT_MAX_COMMITS`,
   `CAD_IMPORT_MAX_BLOB_BYTES`). Exceeding one is refused before anything is
   written.

Nothing is installed and no new dependency is used.

## 3. Import from the command line

```bash
# Import HEAD of ~/code/thing. The project is created (name/slug from the
# directory) and published when sync is configured.
mix cad.import ~/code/thing

# Pick refs explicitly; list several with repeated --ref.
mix cad.import ~/code/thing --ref main --ref v1.0.0

# Every local branch and tag (annotated tags are peeled to their commit).
mix cad.import ~/code/thing --all-refs

# Name the Cadence project explicitly.
mix cad.import ~/code/thing --name "Thing" --slug thing

# Bound the walk. A history longer than N is refused, not truncated.
mix cad.import ~/code/thing --limit 500

# A shallow clone is refused unless you say so.
mix cad.import ~/code/shallow-clone --allow-shallow

# Import into an existing (empty/imported) project instead of by location.
mix cad.import ~/code/thing --project <project-uuid>

# Print the final job JSON instead of the human summary.
mix cad.import ~/code/thing --json
```

The task submits the job, polls `GET /import/:id` until it is `completed` or
`failed`, and prints the summary (imported/reused counts, objects/bytes, tip
node). It exits non-zero on a rejected request or a failed job. One shipped
defect affects the default summary path: without `--json` the task raises a
`FunctionClauseError` **after** a successful job (the job itself is complete;
see §12 below). Use `--json` until it is fixed.

Defaults and semantics:

| Option | Meaning |
|---|---|
| `PATH` | Worktree or bare repository. Required. |
| `--name` | Project name. Defaults to the source directory's basename. |
| `--slug` | Project slug (the `/p/:slug` URL). Defaults to a slugified name; a collision is a validation error. |
| `--ref REF` | Repeatable. Branch, tag, `HEAD`, a full `refs/...` name, or a 40-hex SHA. Defaults to `HEAD`. |
| `--all-refs` | Adds every local branch and tag plus `HEAD`. Remote-tracking refs are not listed. |
| `--allow-shallow` | Permit a shallow clone; boundary commits become roots. |
| `--limit N` | Maximum commits to walk. Effective cap is `min(N, CAD_IMPORT_MAX_COMMITS)`. |
| `--project ID` | Import into an existing project whose location matches `PATH`. |
| `--json` | Print the final job map as JSON. |

`mix cad.import` talks to the daemon socket (`CAD_STATE_DIR/daemon.sock`), so it
also works from a different checkout against a running daemon. A release can
call `Cadence.Daemon.Release.import(path, opts)` instead.

## 4. What the import produces

| Cadence field | Value |
|---|---|
| `git_commit_sha` | The original 40-hex commit SHA. Objects are copied as-is. |
| `message` | The full commit message (subject + body), trailing whitespace trimmed; invalid UTF-8 is replaced so the node stays renderable. |
| `created_at` | The commit's **author** timestamp (committer timestamp if the author line is unreadable). |
| `parents` | Node UUIDs of the commit's parents, in the source order. A root is `[]`; a merge keeps its N parents. |
| `flags` | `[]` — flagless, rendered as the muted unknown dot. |
| `docs_state` | `:skipped` — no local session can generate docs for a historical commit. |
| `created_by` | The importing local user; the server maps it to the pushing user. |
| `pinned` | `true` on the selected ref's tip so the public preview is deterministic. |
| `session_metadata["import"]` | `%{"source" => "git", "author" => name, "author_email" => email, "imported_at" => iso8601}`; selected `refs` are added on tip nodes only. |
| Session pointer | Moved to the imported tip (unless the project already had newer local work). |

Additional outcomes:

- **One node per commit, plus at most one extra.** If the source is a worktree
  whose files differ from the imported tip, the dirty tree is committed once
  against the tip with the message `import: local changes` and becomes the
  pointer. A bare source registers data-only (no watcher/queue), so it gets no
  dirty commit and no later auto-commits.
- **Parents-first insert.** Nodes are inserted in `CAD_IMPORT_PUSH_BATCH`-sized
  transactions, each with its `SyncPending` row. A failed batch rolls back;
  parents always precede children, so a failed run can be resumed by
  re-submitting.
- **One job at a time.** `Cadence.Daemon.ImportTasks` runs a single import at a
  time across all projects; up to 20 may be queued. A second submit for the same
  source path while one is active is refused. Terminal jobs are retained in
  memory (newest 50); jobs are not persisted across a daemon restart.
- **The watcher is suspended** during the insert/pointer phase, so no ordinary
  commit interleaves with the import. It resumes afterwards.

## 5. Caps

All values are environment variables read by the daemon (or server) at call
time; see spec §12.6.

| Variable | Default | Behaviour |
|---|---|---|
| `CAD_IMPORT_MAX_COMMITS` | `2000` | Maximum commits walked. A larger history is a typed `too_many_commits` error and creates no project. Non-positive/invalid falls back to the default. |
| `CAD_IMPORT_MAX_BLOB_BYTES` | `8388608` (8 MiB) | Preflight reads every reachable blob once. The first larger blob is refused with `blob_too_large` (path + size); nothing is written. `0` disables the check; negative/invalid falls back to the default. |
| `CAD_IMPORT_MAX_SECONDS` | `1800` | Wall-clock bound per job. The worker kills the task past it and the job fails with `timeout`. `0` disables. |
| `CAD_IMPORT_ALLOW_SHALLOW` | `false` | Deployment default for a shallow source; `--allow-shallow`/`allow_shallow` overrides per job. |
| `CAD_IMPORT_PUSH_BATCH` | `100` | Nodes inserted and enqueued per transaction batch. Non-positive falls back to the default. |
| `CAD_DAG_MAX_NODES` | `150` | Server only: nodes rendered in the public project DAG. Older commits stay in the data. |
| `CAD_DAG_INTRO_MAX_NODES` | `60` | Server only: skip the DAG intro when the project has more nodes than this. |
| `CAD_SYNC_MAX_PUSH_PARENTS` | `8` | Server only: maximum parents an **owner** may push for an imported merge. Ordinary pushes stay at 1; invalid/non-positive falls back to 1. |
| `CAD_SYNC_MAX_BODY_BYTES` | `67108864` (64 MiB) | Server only: body limit for `/sync/*`. The browser/public routes keep Plug's 8 MiB default. |

The per-node push payload is not re-checked against a separate import cap: the
blob cap plus the sync body limit are the bounds. A commit whose whole tree is
large (but under 8 MiB per blob) can still exceed the 64 MiB body limit; the
push then fails on that node and stays queued, and the import report shows the
server error. Raise `CAD_SYNC_MAX_BODY_BYTES` or shrink the history.

## 6. Source edge cases and limitations

- **Shallow clones.** A `shallow` file means boundary commits have no parents.
  By default the import is refused (`shallow_repository`) because the DAG would
  silently look like a set of roots. With `--allow-shallow` (or
  `CAD_IMPORT_ALLOW_SHALLOW=true`) the boundary commits are imported as roots and
  the job reports `shallow: true`. The missing history stays missing.
- **Git LFS.** Cadence imports the pointer file (a few hundred bytes), not the
  object it names. Snapshots show the pointer text; no LFS API is called. If you
  need the content in Cadence, import a repository that already has the real
  files (for example after `git lfs migrate export` in a copy) or accept the
  pointer. Do not raise the blob cap to "fix" LFS.
- **Submodules.** A gitlink (mode `160000`) is preserved as a `commit` tree
  entry but its target repository is not copied. The repository browser renders
  a non-clickable `submodule` row, and secret scans/pushes skip the entry. The
  superproject history imports correctly; the submodule's history does not.
- **`objects/info/alternates`.** Not followed. A repository that borrows objects
  from another store (shared clones, `git clone --reference`) hits a missing
  object and fails with `missing_object` (or `invalid_source` if the object is
  unreadable). Run `git repack -a -d`/`git clone --no-local` in a copy first to
  make the source self-contained.
- **Annotated tags** are peeled to their commit for ref selection, but the tag
  object itself is not copied into the Cadence store. Tag names are recorded in
  the tip node's `session_metadata["import"]["refs"]`, not as Git refs.
- **Packed refs** are read (`packed-refs`, loose wins), and packed objects are
  read through the shared pack layer. Remote-tracking refs are resolvable by
  name but are not included by `--all-refs`.
- **Corrupt/unreadable objects.** A commit, tree, or blob that cannot be decoded
  fails the job with a typed error before the project is created; the import
  never partially registers a project on a validation failure.

## 7. Historical secrets: read this before importing

Cadence's public repository browsing shows historical snapshots. Old
repositories often contain credentials that were committed and later deleted —
they are still in the history, and importing them makes them part of the DAG
(though never of the public render).

**The import never bypasses the secret scan.** When a node is pushed, the
server scans the snapshot; a high-confidence secret quarantines that node's
public snapshot and opens a critical `secret_detected` incident (spec §6.7,
§7.6). Consequences:

- The node still appears in the DAG with its flag; its public repository pane
  shows the generic "snapshot hidden for review" notice.
- The commit message is redacted by the same scanner where it is rendered.
- Descendant commits that no longer contain the file are **not** quarantined,
  so the rest of the import is browsable.
- Resolving the incident is an acknowledgment, not a fix. The value is still in
  the history.

Rotate every secret the source repository ever contained **before** publishing.
If you cannot rotate it, do not import that repository (or import a filtered
copy produced with `git filter-repo`). The import report and
`GET /import/:id` expose the quarantine indirectly: the job completes, and the
affected node shows up with an incident on the project page/review hub.

A secret in a file with a sensitive basename (`.env`, `*.pem`, `id_rsa`, …) is
hidden by path filtering even if the pattern scanner misses it, but a secret in
an innocuous file (for example `config.txt`) is exactly what the scan catches.

## 8. Publication, offline behaviour, and re-runs

Publication uses the normal sync path (`POST /sync/projects`, then
`POST /sync/nodes` in parents-first batches). Nothing about it is special-cased
for imports except the §10.2 merge exception:

- **Owner only.** Imported merge nodes (`> 1` parent) publish only when the
  pushing user is the project **owner** and the node carries
  `session_metadata["import"]["source"] == "git"`, capped by
  `CAD_SYNC_MAX_PUSH_PARENTS`. A trusted member's import keeps one parent per
  node on the server (the merge is refused), so run imports with the owner's
  token.
- **The pin follows the owner.** The server stores `pinned: true` from the push
  only for an owner; a trusted member's tip is not pinned server-side.
- **Offline is fine.** If no server is configured, or the server is unreachable,
  the import completes locally. The nodes and their sync rows stay in the
  ledger and drain on the next successful sync pass (on boot, on the interval,
  or when the daemon is woken). No manual "publish" command exists, and none is
  needed.
- **Re-runs are idempotent.** A second import of the same source is keyed by
  `(project_id, git_commit_sha)`: existing commits are counted as `reused` and
  no node, object, or sync row is duplicated. It also does not rewind the
  session pointer if local work exists past the tip, and it does not create a
  second `import: local changes` node. Re-submitting is the recovery path after
  a failed batch or a timeout.
- **A project with non-imported nodes is refused** (`project_not_importable`,
  409). Create a new project for a fresh import; an import-created project may
  keep growing with ordinary commits and still accept a re-run of the same
  source.
- **New commits in the source are picked up by a re-run.** Importing the same
  path again with the ref that advanced adds only the missing commits (the
  walk sees them; existing SHAs are reused). This is the incremental-sync path.

## 9. The daemon socket API

The same jobs are available over the daemon's Unix socket
(`CAD_STATE_DIR/daemon.sock`). This is what `mix cad.import` and the release
helper use.

### `POST /import`

Body (JSON; unknown keys are ignored, all keys optional except `work_dir`):

```json
{
  "work_dir": "/home/me/code/thing",
  "refs": ["main", "v1.0.0"],
  "all_refs": false,
  "allow_shallow": false,
  "limit": 500,
  "project_id": "0f0e…",
  "name": "Thing",
  "slug": "thing"
}
```

`202 Accepted`:

```json
{
  "job": {
    "id": "5b1c…",
    "status": "queued",
    "project_id": "0f0e…",
    "project_slug": "thing",
    "source": {"path": "/home/me/code/thing", "kind": "worktree"},
    "refs": ["refs/heads/main"],
    "tips": ["a1b2…"],
    "tip": "a1b2…",
    "total": 51,
    "merge_commits": 1,
    "imported": 0,
    "reused": 0,
    "objects": 0,
    "bytes": 0,
    "largest_node_bytes": 12345,
    "shallow": false,
    "error": null,
    "tip_node_id": null,
    "dirty_node_id": null,
    "created_at": "2026-11-11T12:00:00Z",
    "started_at": null,
    "finished_at": null
  }
}
```

Validation and planning happen before the 202: ref resolution, the commit walk,
shallow detection, and the blob preflight all run synchronously, so a bad source
is rejected without creating a project or a job.

### `GET /import/:id`

`200 OK` with `{"job": …}` (same shape; `status` is `queued | running |
completed | failed`, `imported`/`reused`/`objects`/`bytes` advance while
running, and `error` is `{"code", "message", …}` on failure). `404` for an
unknown or malformed id.

### Status codes

| Status | Meaning |
|---|---|
| `202` | Job queued. |
| `200` | Job found. |
| `400` | The request body is not valid JSON (Plug's parser; no handler runs). |
| `404` | Unknown job, or `project_id` does not exist. |
| `409` | `project_location_mismatch`, `project_not_importable`, or `import_in_progress`. |
| `422` | Invalid payload (`work_dir`, `refs`, `limit`, `project_id`, …), not a directory/repository, invalid `.git` redirect, unreadable object, unknown ref, ref not a commit, no refs, shallow source, `too_many_commits`, `blob_too_large` (path + size), or `missing_object`. |
| `429` | More than 20 imports queued/running. |
| `503` | The importer process is unavailable (daemon stopping). |
| `500` | Unexpected failure (`error: "import failed"`). |

Typical failure codes in `job.error.code`: `timeout`, `shallow_repository`,
`too_many_commits`, `blob_too_large`, `missing_object`, `missing_parent`,
`project_unavailable`, `pointer_failed`, `dirty_commit_failed`, `invalid_node`,
`exception`.

## 10. Browsing the result

After publication (or locally via the daemon), the project is at:

| URL | Shows |
|---|---|
| `/p/:slug` | The newest `CAD_DAG_MAX_NODES` commits in the DAG, the preview node, and the repository pane. Above the cap it reads "Showing the newest N of M commits" with a link to History. |
| `/p/:slug/history` | The full newest-first list, 50 rows per page (`?page=N`): redacted message (linked), imported author display name, date, 12-character SHA. This is the escape hatch for commits outside the DAG window. |
| `/p/:slug/n/:node_id` | One commit's snapshot and pane. Imported nodes show `Imported from git · <author>`; the author email is visible only to owners/trusted members. A node older than the rendered window still opens and links back to its History row. |

The tip is pinned, so `/p/:slug` opens at the imported tip. Commits are flagless
and show the muted unknown dot; `docs_state` reads "docs skipped". A
quarantined node still appears in the DAG and History but its public pane says
the snapshot is hidden.

## 11. Upgrade and migration notes

- **No schema change and no new table.** Import state is in memory; nodes use
  the existing `Node` schema and the existing `sync_pending` ledger.
- **Version skew.** `POST /import` did not exist before Phase 9b; a daemon older
  than the server is fine, a daemon newer than the CLI is not (the CLI always
  matches its daemon). The server must be at least the Phase 9c level
  (`CAD_SYNC_MAX_PUSH_PARENTS`) to accept imported merges; on an older server the
  merge node (and its descendants) stay queued with `multiple_parents` until it
  is upgraded.
- **Existing projects.** Importing into a project that already has nodes only
  works when every existing node is import-marked (an earlier import). A project
  with hand-made nodes is refused; create a new project.
- **Old imported nodes** keep their stored metadata (including refs on the tip
  at import time). Re-running with new refs does not rewrite existing nodes; it
  only adds commits.
- **Bare vs. worktree is remembered** by the location row: a bare import is
  restored data-only on rehydrate, so a daemon restart never starts watching a
  bare repository.
- **Rollback** is simply deleting the project (local and server). The source
  repository is untouched.

## 12. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `import rejected (422): work_dir is not a Git repository` | The path is not a worktree (`.git` directory or redirect) or a bare repo (`HEAD` + `objects/`). Point at the repository root, not a subdirectory. |
| `ref not found` / `ref does not resolve to a commit` | `--ref` takes a branch, tag, `HEAD`, full `refs/...`, or 40-hex SHA. A tag pointing at a blob/tree is not importable. |
| `history exceeds the 2000-commit limit` | Raise `CAD_IMPORT_MAX_COMMITS` (and restart the daemon), or pass `--limit` below it to import a prefix intentionally. The cap is never silently applied. |
| `blob too large: path (N bytes)` | A file exceeds `CAD_IMPORT_MAX_BLOB_BYTES`. Use LFS/filter-repo in the source, or raise the cap deliberately and expect a large push. |
| `missing Git object <sha>` | Shallow clone without `--allow-shallow`, a shared clone using `objects/info/alternates`, or a damaged store. Make the source self-contained (`git repack -a -d`, `git clone --no-local`). |
| `source is a shallow clone; pass allow_shallow` | Expected default. Pass `--allow-shallow` only if losing the pre-boundary history is acceptable. |
| `project already has nodes that were not imported` | Pick a new project (drop `--project`, use `--name`/`--slug`). |
| `an import is already queued or running for this source` | Wait for the active job (`GET /import/:id`), or re-run after it finishes. Jobs are one at a time. |
| Import completes but the public page is missing / stale | Sync is offline or the token is not an owner. Check the daemon log and the server's `/sync/*` responses; the nodes stay queued. |
| A merge node never appears on the server | The pushing user is not the project owner, or the server predates 9c. `trusted` members cannot publish multi-parent nodes. |
| `import failed: timeout` | `CAD_IMPORT_MAX_SECONDS` (default 30 min) was exceeded. The insert batches that committed are durable; re-run to resume (idempotent). Raise the bound for a very large history. |
| A node's public snapshot is hidden | Expected: the push scan found a high-confidence secret and opened a critical incident. Rotate the secret; resolve the incident as an acknowledgment when done. |
| `mix cad.import` raises `FunctionClauseError ... report/2` after a successful import | Known Phase 9b defect: the task passes `opts[:json]` (nil when the flag is absent) to `report/2`, which only matches booleans, so the default summary path crashes *after* the job completed. Pass `--json` (or use `POST /import` and `GET /import/:id`) until it is fixed; the import itself succeeded. |
| `/p/:slug` shows fewer commits than were imported | Expected above `CAD_DAG_MAX_NODES` (default 150). Use `/p/:slug/history` or the "Showing the newest N of M" link for the rest. |
| Imported author is missing from a History row | Older/non-imported nodes have no `session_metadata["import"]`; the column renders `—`. Imported nodes always carry the source author. |

## 13. References

- Spec §5.7 — normative import pipeline (validation → refs → walk → copy →
  insert → pin/pointer → dirty tree → publication → idempotency).
- Spec §7.3 — DAG render cap, History list, import provenance.
- Spec §10.2 — the owner-only multi-parent push exception.
- Spec §12.6 — every `CAD_IMPORT_*`, `CAD_DAG_*`, and sync cap.
- Spec §13 Phase 9 — the slice history (9a–9e).
- `docs/daemon-setup.md` — daemon install, token, env, migration, upgrades.
- `docs/demo.md` — the seeded demo stack used for manual checks.
