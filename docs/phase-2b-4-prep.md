# Phase 2b-4 prep — Preferences, notification channel, resilience

> Status: **2b-4a and 2b-4b complete/committed** (versioned preferences,
> server transport, daemon push/apply); 2b-4c next. Cold-start brief:
> `docs/phase-2b-4b-prep.md` (completed). Canonical contract: `docs/spec.md`
> §4.3, §10.5, §10.6, §11, §13.

Phase 2b-4 makes multi-machine continuity real and tightens sync failure
handling. Sync remains local-first: preferences and notifications are hints,
while the DAG itself still moves over the cursor-based HTTP protocol.

## 1. Scope

- Versioned per-user/per-project preferences (`active_heads`, `session_pointer`).
- `POST /sync/preferences` plus preferences in the node pull response.
- Daemon dirty tracking and apply-if-newer behavior.
- A notification-only Phoenix Channels socket from server → daemon.
- Partial-batch failure isolation.
- Two-daemon convergence acceptance.

Out of scope: unions, doc automation, web UI, object negotiation.

## 2. Decisions

1. **Preference conflict policy:** timestamp last-write-wins. Add
   `Membership.preferences_updated_at :utc_datetime_usec`; a write wins only
   when its timestamp is strictly newer than the stored one.
2. **Preferences transport:** `POST /sync/preferences` for writes, and include
   the caller's current preferences in `GET /sync/nodes` responses. This avoids
   a second cursor and keeps pull atomic with the node batch.
3. **Notification transport:** Phoenix Channels + `slipstream` in the daemon.
   The socket carries only a `sync_available` hint (with `project_id`); the
   daemon then pulls over HTTP. Polling remains enabled as the correctness
   fallback.
4. **Socket auth:** daemon API key in an `x-cadence-token` header; server socket
   `connect_info` includes `:x_headers`. Never put the token in the query string.
5. **Channel scope:** each daemon joins `sync:user:<server_user_id>`. The server
   broadcasts only after writes by that user (`push_nodes`, `push_preferences`,
   later unions). The existing `project:<id>` PubSub topic stays for web UI.
6. **Partial batches:** server returns `failed_local_id` on fail-fast node
   errors; daemon marks only that node failed and retries the rest. Descendants
   of a failed parent remain pending and retry after the parent.
7. **Polling:** `SyncWorker` keeps its interval and wake-on-enqueue behavior.
   Socket events call `SyncWorker.wake(project_id)`.

## 3. Data model

`Membership` gains:

```
preferences_updated_at  :utc_datetime_usec  # nil = never pushed
```

Daemon and server migrations add the nullable column. Existing rows are treated
as having no preference version.

`PushPreferences` wire shape becomes:

```
%{project_id, active_heads, session_pointer, updated_at}
```

`PullNodesResponse` gains:

```
preferences: %{active_heads, session_pointer, updated_at} | nil
```

## 4. Server

- `Sync.pull_nodes/3` returns the caller’s preferences with nodes/cursor.
- `Sync.push_preferences/2`:
  - owner/trusted only,
  - validates `project_id`, UUID arrays, optional UUID pointer, ISO8601 version,
  - updates only when newer; stale writes return the current preferences,
  - sets `last_seen_at`,
  - broadcasts `{:preferences_updated, project_id, user_id}`.
- `POST /sync/preferences` exposes the push.
- Socket/channel modules arrive in 2b-4d.

## 5. Daemon

- `SyncLedger` tracks local preference dirty state and the last pushed version.
- `Session` mutations (switch/commit/spawn) mark preferences dirty.
- `Sync.push_preferences/1` runs after node pushes.
- `Sync.pull` applies remote preferences only when newer than local, filters
  `active_heads` to nodes present locally, and does not mark them dirty.
- `Cadence.Daemon.SyncSocket` (2b-4d): `use Slipstream`, connect with
  `x-cadence-token`, join `sync:user:<id>`, handle `sync_available`, reconnect
  and rejoin via Slipstream. `Req.Test` remains the HTTP testing path;
  `Slipstream.SocketTest` covers the client callbacks plus one real local socket
  integration test.

## 6. Slices

1. **2b-4a — Versioned preferences + server transport. ✅ Done.**
   Schema/migrations, `PushPreferences`/`PullNodesResponse`, pull preferences,
   `POST /sync/preferences`, versioning/broadcast/auth tests.
2. **2b-4b — Daemon preferences. ✅ Done.**
   Ledger dirty/version state, `Session` dirty marking, push/apply, tests.
3. **2b-4c — Partial batches.**
   `failed_local_id`, isolate bad nodes, preserve parents-first retry behavior.
4. **2b-4d — Phoenix Channels accelerator.**
   `{:slipstream, "~> 1.2"}` in the daemon, server socket/channel, daemon
   client, reconnection/fallback tests.
5. **2b-4e — Convergence + docs.**
   Two-daemon preference journey, socket-down fallback, spec/plan/progress
   finalization.

## 7. Acceptance

- A writes `session_pointer`/`active_heads`; B pulls the same values.
- Stale preference writes do not clobber newer state.
- A channel `sync_available` event wakes the correct project quickly; polling
  still converges if the socket is unavailable.
- A single invalid pending node does not block unrelated nodes.
- No sync work blocks commits or the daemon API.
