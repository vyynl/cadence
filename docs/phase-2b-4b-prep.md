# Phase 2b-4b prep — Daemon preference push/apply

> Cold-start brief for the next session. **2b-4a is committed** (`25d6dfb`).
> Read `docs/spec.md` §4.3/§10.5/§10.6, `docs/phase-2b-4-prep.md`, and
> `docs/progress.md` first. This slice is daemon-only plus fake-server tests;
> do not add `slipstream` yet (2b-4d).

## 1. Goal

Make `active_heads`/`session_pointer` travel between daemons using the server
endpoint added in 2b-4a, with last-write-wins versioning.

Acceptance:
- A local switch/commit/spawn advances the local preference version.
- Dirty local preferences push to `POST /sync/preferences` and clear locally.
- A newer remote preference applies locally; an older remote value is ignored.
- Applying remote preferences does not echo them back as dirty.
- Offline preference changes persist locally and flush later.
- No preference work blocks commits or the daemon API.

## 2. Current state (verified)

- `Membership.preferences_updated_at` exists in the shared schema and both
  daemon/server migrations. It is nullable; `nil` means “never synced”.
- Server `POST /sync/preferences` is live:
  body `%{project_id, active_heads, session_pointer, updated_at}`;
  it accepts only strictly newer writes, returns `%{preferences: ...}` (stale
  writes return the current server value with 200), and broadcasts
  `{:preferences_updated, project_id, user_id}`.
- `GET /sync/nodes` returns `preferences: %{active_heads, session_pointer,
  updated_at} | nil`.
- `SyncClient.pull/2` **currently drops the `preferences` field**; fix this
  first. It only returns `%{nodes, cursor}`.
- `SyncClient` has no `push_preferences/1`.
- `Sync.pull_batch/2` calls `SyncClient.pull/2`; `Sync.do_pull/2` only carries
  the cursor.
- `Sync.sync/1` runs `push_pending` then `pull`; no preference step.
- `SyncLedger` has no preference state (only pending/cursors/state).
- `Session.switch/2`, `commit_after/2`, and `spawn_after/3` update membership
  fields but never set `preferences_updated_at` or wake sync.
- `Session.ensure_membership!/1` creates a membership with `nil` version. Keep
  it that way; setting a version on first boot would clobber another machine’s
  preferences.

## 3. Data model

Add a daemon-only table + schema:

```text
sync_preferences
  project_id       binary_id PK
  pushed_updated_at utc_datetime_usec
  remote_updated_at utc_datetime_usec
  last_error       text
  updated_at       utc_datetime_usec NOT NULL
```

No explicit `dirty` flag: local dirtiness is
`membership.preferences_updated_at > sync_preferences.pushed_updated_at`
(treat `nil` pushed version as older).

`last_error` is diagnostic; preference pushes are retried on the next sync
cycle, not through the node pending queue.

## 4. Files / changes

### `Cadence.Daemon.SyncPreference` + migration

- Schema `"sync_preferences"`, primary key `project_id`.
- Migration timestamp after `20261023000200_add_membership_preferences_updated_at`
  (e.g. `20261023000300_create_sync_preferences`).

### `Cadence.Daemon.SyncLedger`

Add:
- `preferences_state(project_id)` → `%{pushed_updated_at, remote_updated_at,
  last_error}` or nil.
- `mark_preferences_pushed(project_id, version)` — set pushed + remote to
  `version`, clear error.
- `mark_preferences_remote(project_id, version)` — remote applied locally; set
  pushed + remote to `version`, clear error.
- `mark_preferences_error(project_id, reason)` — store a bounded error string.
- `preferences_changed(project_id)` — cast; wake `SyncWorker` if sync is
  configured. Reuse the existing `notify_worker/1` guard.

### `Cadence.Daemon.Session`

- `switch/2`, `commit_after/2`, `spawn_after/3`: set
  `preferences_updated_at: DateTime.utc_now()` (usec) in the same changeset.
- After a successful update, call
  `SyncLedger.preferences_changed(project_id)`.
- Do **not** set a version in `ensure_membership!/1`.

### `Cadence.Daemon.SyncClient`

- `pull/2`: return `%{nodes, cursor, preferences}`; default `preferences` to
  `nil` if absent.
- Add `push_preferences/1`:
  - Accept `%Cadence.Shared.Sync.PushPreferences{}` (or a map with the same
    keys).
  - POST flat JSON body to `/sync/preferences`.
  - Return `{:ok, %{preferences: map}}` or `{:error, reason}`.

### `Cadence.Daemon.Sync`

- Add `push_preferences/1`:
  1. Load the local user’s `Membership`; if missing or version `nil`, `:ok`.
  2. Compare with `SyncLedger.preferences_state/1`.
  3. If local version is newer, push `active_heads`, `session_pointer`, and
     ISO8601 `updated_at`.
  4. Inspect the returned server preferences:
     - server version newer than local → server won; apply it,
     - otherwise mark local version pushed,
     - on error → record error and retain local state.
- Extend `pull`:
  - Capture `preferences` from each batch; apply only the latest after
    `do_pull/2` finishes catching up. This ensures a remote `session_pointer`
    usually references an already-imported node.
- Add `apply_remote_preferences/2`:
  - Parse `updated_at`; ignore `nil` or `<=` local version.
  - Filter `active_heads` to node IDs that exist locally.
  - Apply `session_pointer` only if that node exists; otherwise leave the local
    pointer unchanged.
  - Update local membership and set its `preferences_updated_at` to the remote
    version.
  - Call `SyncLedger.mark_preferences_remote/2` so it is not echoed.
- `sync/1` order: `push_pending` → `push_preferences` → `pull`.
  Preference-push failure should not prevent pulling; return an error after the
  pull if needed, but still converge nodes.

## 5. Fake server test support

Extend `Cadence.Daemon.TestSyncServer`:
- Store per-project preferences in Agent state.
- `POST /sync/preferences`: LWW compare, return current preferences.
- `GET /sync/nodes`: include `preferences` in the response.
- Helpers to inspect/set preferences directly for tests.

## 6. Tests

- `Session`: switch/commit/spawn set `preferences_updated_at`; initial
  membership leaves it nil; ledger wake is harmless when unconfigured.
- `SyncLedger`: preference state round-trip, mark pushed/remote/error,
  `preferences_changed` wake behavior.
- `SyncClient`: `pull` preserves preferences; `push_preferences` sends the
  correct body/header and parses the response.
- `Sync.push_preferences`: sends only when local is newer; marks pushed; applies
  a newer server response and does not echo.
- `Sync.pull`: applies newer remote prefs; ignores older; filters unknown
  `active_heads`; preserves pointer when its node is absent.
- End-to-end: switch locally → sync → fake server has preferences → clear local
  membership state → sync/pull applies them.
- Offline: local switch remains unsynced and flushes after configuration.

## 7. Gotchas

- `SyncClient.pull/2` currently drops `preferences`; that is the first change.
- Prefer UTC `DateTime` with microseconds; serialize with `DateTime.to_iso8601`.
- Server stale writes return **200** with the current preferences, not an error.
  The client must compare versions in the response.
- Do not mark remote-applied preferences dirty/pushed-to-be-sent again.
- Do not set `preferences_updated_at` during initial membership creation.
- Keep node sync and preference sync independent: preferences never enter
  `sync_pending`.
- Do not add `slipstream` in this slice.

## 8. Acceptance commands

```bash
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=prod mix compile --warnings-as-errors
mix test apps/cadence_shared/test
mix test apps/cadence_daemon/test
# server needs Postgres on 55432
mix test apps/cadence_server/test
```
