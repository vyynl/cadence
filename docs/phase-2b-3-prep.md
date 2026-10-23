# Phase 2b-3 prep — Daemon sync ledger + client

> Status: implemented. `SyncLedger`, `SyncClient`, `Sync`, `SyncWorker`,
> commit/spawn enqueue hooks, boot rehydrate, and server project provisioning
> are in place. Next milestone is 2b-4 (preferences + broadcast + resilience).
>
> Cold-start notes written after 2b-2. The deliverable is the daemon side of
> sync: persistent pending/cursor state, an HTTP client, and the boot/commit
> integration. This is **not** a spec replacement; see `docs/spec.md` §10 and
> `docs/phase-2b-cloud-sync.md` §7/§12.

## 1. Current state

- Server endpoints are live:
  - `POST /sync/nodes` — one project per batch, parents-first, fail-fast,
    identity node IDs, base64 Git objects, bearer API key.
  - `GET /sync/nodes?project_id=<uuid>&since=<seq>` — `nodes.seq` cursor,
    `CAD_SYNC_PULL_LIMIT`, objects included per node.
  - `GET /sync/me` returns the authenticated server user ID.
- Node IDs are identity-mapped: local UUID == cloud UUID. Push retries are
  idempotent.
- The daemon already has `GitStore`, SQLite (`Cadence.Daemon.Repo`), per-project
  `CommitQueue`, `Session`, and `ProjectLocation` (`git_dir`).
- `CommitQueue.do_commit/2` currently ends with the local insert +
  `Session.commit_after/2`; no sync hook exists.
- The daemon has no `CAD_SERVER_URL`/`CAD_AUTH_TOKEN` config yet.

## 2. Decisions to make first

1. **Ledger schema.** Implemented as three daemon-only tables:
   - `sync_cursors(project_id uuid PK, cursor text, updated_at)`
   - `sync_pending(node_id uuid PK, project_id uuid, enqueued_at, attempts,
     last_error, next_attempt_at)`
   - `sync_state(key text PK, value text, updated_at)` — holds the global
     `server_user_id` and the one-time backfill marker.
   Since IDs are identity-mapped, there is no local↔cloud node table.
2. **Worker shape.** Recommended: keep `SyncLedger` as the persistent
   GenServer/owner and add a small `SyncWorker`/`Task.Supervisor` for network
   calls so a slow/invalid server never blocks commits or the API. A single
   worker per project is enough.
3. **Project provisioning.** Still unresolved (spec §16). 2b-3 tests should
   seed a server project/membership whose IDs match the local project. Live
   sync still needs a registration path.
4. **Server user mapping.** The server sets `created_by` to the authenticated
   server user. On pull, the daemon should map nodes created by *this* user to
   `Env.local_user_id()` so `DAG`/`Session` "most recent by current user"
   works. Store `server_user_id` (from `/sync/me`) in `sync_cursors` or a small
   global sync state table. Other users' nodes keep the server UUID for
   attribution.
5. **HTTP test stub.** Prefer `Req.Test` (already available through `Req`) over
   adding `Bypass` to spec §11. `Bypass` would require a spec dependency
   update.

## 3. Proposed modules

- `Cadence.Daemon.SyncLedger` — GenServer + Repo:
  - `enqueue(project_id, node_id)`
  - `pending(project_id)` (ordered parents-first)
  - `mark_pushed(node_id)`
  - `cursor(project_id)` / `put_cursor(project_id, cursor, server_user_id)`
  - `rehydrate/0` on boot
- `Cadence.Daemon.SyncClient` — thin Req wrapper:
  - `me/0` → `{:ok, server_user_id}`
  - `push/2` → POST `/sync/nodes`
  - `pull/3` → GET `/sync/nodes?project_id=&since=`
  - bearer header, `CAD_SYNC_TIMEOUT_MS`, no automatic retry inside the client
- `Cadence.Daemon.Sync` — orchestration:
  - `push_pending(project_id)`
  - `pull(project_id)`
  - `sync(project_id)` (push then pull loop until cursor stops advancing)
- Optional `Cadence.Daemon.SyncWorker` — `Task.Supervisor` child for one
  project's network cycle.

## 4. Push flow

1. Load pending nodes for the project, ordered by `created_at, id`
   (parents-first; local parents always predate children).
2. For each node:
   - open the project store (`ProjectLocation.git_dir`),
   - `GitStore.objects_from/2` for the commit,
   - build metadata from the local `Node`:
     `project_id`, `git_commit_sha`, `parents`, `flags` (strings),
     `message`, `session_metadata`, `created_at` (ISO8601), `docs_state`,
     `pinned`.
   - base64-encode each object payload with its type/SHA.
3. POST the batch. On 200, clear `sync_pending` rows for the returned
   mappings. On 422/409 (permanent) record the error; on 5xx/timeout/network
   schedule retry with backoff. Never block the commit path.
4. A node whose parent is still pending will be rejected as out-of-order; the
   next cycle retries after the parent succeeds.

## 5. Pull flow

1. Ensure `server_user_id` is known (`/sync/me`) and stored.
2. GET with the project's cursor (empty → beginning).
3. Import each node's `git_objects` into the local store with
   `GitStore.import_objects/2`.
4. Insert nodes idempotently:
   - existing same node ID + same commit/parents → skip,
   - existing different content → log and stop (do not advance cursor),
   - new → insert with `created_by` mapped (current server user →
     `Env.local_user_id()`, otherwise keep server UUID).
5. Only after all nodes import/insert successfully, persist the new cursor.
6. Repeat while the response contains nodes and the cursor advances.

## 6. Config

Add to `config/runtime.exs` and spec §12.6:

- `CAD_SERVER_URL` (absence ⇒ offline mode)
- `CAD_AUTH_TOKEN` (absence ⇒ offline mode)
- `CAD_SYNC_ENABLED` (default `true`)
- `CAD_SYNC_TIMEOUT_MS` (already listed; default `5000` for network calls)
- `CAD_SYNC_PUSH_INTERVAL_MS`
- `CAD_SYNC_RETRY_BACKOFF_MS`
- `CAD_SYNC_MAX_ATTEMPTS` (optional)

No secrets in source; token belongs in `~/.config/cadence/env`.

## 7. Integration points

- `CommitQueue.do_commit/2`: after `Session.commit_after/2`, call
  `SyncLedger.enqueue(project_id, node.id)` (cast/async). Spawn nodes too.
- `Application`: supervise `SyncLedger` and `SyncWorker`/`Task.Supervisor`;
  call `SyncLedger.rehydrate/0` after the registry boots.
- On boot/reconnect, flush pending pushes and resume pulls. If offline, leave
  pending rows intact and retry later.
- `:CadOpen`'s 500 ms sync attempt (§6.3) can call `Sync.sync/1` later; it is
  not required for 2b-3.

## 8. Tests

- Ledger migration/persistence: pending rows survive restart; cursor
  round-trip; ordering is parents-first.
- `SyncClient` with `Req.Test`: bearer header, push body/object encoding,
  query params, 401/403 no retry, 5xx/timeout backoff.
- `Sync`: local commit → enqueue → push clears pending; pull imports objects,
  inserts nodes, advances cursor; duplicate pull is idempotent; sibling pull.
- `created_by` mapping for the current server user.
- Offline (`CAD_SERVER_URL`/token absent) and `CAD_SYNC_ENABLED=false` do not
  crash boot or commits.
- Boot rehydrate flushes pending work.
- Full two-instance convergence may be deferred to 2b-4 once preferences
  travel; for 2b-3, prove one daemon pushes and a clean local store pulls the
  same DAG.

## 9. Acceptance for 2b-3

- A local commit is queued, pushed with a bearer token, and the pending row
  clears.
- A clean daemon store pulls the pushed DAG, imports objects, inserts nodes,
  and can check out the same trees.
- Offline commits remain pending and flush on reconnect.
- No network call blocks the commit path or the daemon API.
- Tests use `Req.Test`; no new production dependency.
