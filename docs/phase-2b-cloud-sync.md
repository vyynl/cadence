# Phase 2b — Cloud Sync (implementation plan)

> **Status: plan only.** No code has been written for this phase yet. This
> document is the cold-start brief for the next session. The canonical contract
> remains `docs/spec.md` (especially §5, §10, §12, §13).

Phase 2b delivers the local↔cloud sync path: a Phoenix server that stores a
project's DAG, token-authenticated push/pull endpoints, and the daemon's sync
ledger + client. It is what makes "work on machine A, resume on machine B"
(§1 use case 4) real.

---

## 1. Scope

**In scope**
- Manual Phoenix scaffold for `cadence_server` (no `mix phx.new`), Postgres
  `Repo`, endpoint, PubSub.
- Bearer-token authentication for daemons; a `User` resource + personal access
  token (AshAuthentication scaffolds OAuth for humans, but token issuance is the
  Phase 2b concern — see open decisions).
- Git **object transfer** between daemon and server (new `GitStore` API).
- Sync endpoints: `POST /sync/nodes`, `GET /sync/nodes?since=`, and the
  preferences channel (`POST /sync/preferences`).
- Daemon `SyncLedger` + `SyncClient`, wired into the commit pipeline and boot
  rehydration.
- Conflict handling per §10.4 (a pushed node becomes a sibling).
- Server PubSub broadcast on writes (§10.2) — clients may ignore it until later.

**Out of scope (later phases)**
- Union/meld and proposals (§6.5/§6.6, Phase 4).
- Web UI / LiveView (Phase 3) — the server scaffolds Phoenix but no views yet.
- Sync object negotiation so clients don't re-push known objects (§13 Phase 7).
- Doc automation, Docker actions.
- Multi-user conflict *UX* (§16).

---

## 2. Current state (verified this session)

- `cadence_shared` already has: `Node`/`Project`/`Membership` schemas, the
  `Sync.*` protocol structs (`PushNodes`, `PushNodesResponse`, `PullNodes`,
  `PullNodesResponse`, `PushPreferences`, `Union`, `UnionResponse`), a ref-less
  `GitStore`, `DAG`, `Diff`, and the LLM client.
- `cadence_daemon` is a working local daemon (watcher → commit queue → SQLite →
  Unix-socket API) with `Session`/`DAG` and an async message queue.
- `cadence_server` is a **stub**: `Application` supervises nothing;
  `Cadence.Server` is a doc-only module; `mix.exs` depends only on
  `cadence_shared`.
- `GitStore` has **no public raw-object read/write or reachability walk** — this
  is the first thing Phase 2b must add.

---

## 3. Server scaffold (manual)

`apps/cadence_server/mix.exs` — add deps (all already listed in spec §11;
confirm current versions at implementation time):
`phoenix`, `phoenix_pubsub`, `bandit`, `plug`, `ecto_sql`, `postgrex`, `jason`,
`ash`, `ash_authentication`. (`phoenix_live_view` stays out until Phase 3.)

New modules:
- `Cadence.Server.Repo` — `Ecto.Repo`, `otp_app: :cadence_server`,
  `adapter: Ecto.Adapters.Postgres`.
- `Cadence.ServerWeb.Endpoint` — Phoenix endpoint (Bandit adapter).
- `Cadence.ServerWeb.Router` — `/health`, `/sync/*`, plus Auth routes later.
- `Cadence.Server.Application` — supervise `Repo`, `Phoenix.PubSub`, `Endpoint`,
  and the sync context supervisor.
- `config/runtime.exs` server section (mirrors spec §12.5): `CAD_PHX_HOST`,
  `CAD_SECRET_KEY_BASE`, `CAD_DATABASE_URL`, `CAD_DB_POOL_SIZE`.

Migrations (Postgres), mirroring `cadence_shared` schemas + server-only rows
(see §5). `parents` uses `uuid[]` **with a GIN index** (§4.1).

> AGENTS §4: never run `mix phx.new`; create files by hand. Every value comes
> from `CAD_*` env vars in `runtime.exs`.

---

## 4. Authentication

- **Daemons** authenticate with `Authorization: Bearer <personal-access-token>`.
  A `Cadence.Server.Accounts` context validates a hashed token and resolves the
  owning `user_id`. A Plug (`Cadence.ServerWeb.AuthPlug`) puts it in the conn and
  rejects with 401 otherwise.
- **Humans** use AshAuthentication OAuth (spec §7.4). For Phase 2b we only need
  the `User` resource to exist so tokens can reference it; OAuth routes can be
  scaffolded but are not required to accept a token.
- Endpoints scope every read/write to projects the user is a member of
  (`Membership` role `owner`/`trusted`).

Open decisions: **how tokens are issued in 2b** (CLI mix task writing a hashed
token vs. a one-off seeded token), and token scope granularity (per-user vs
per-project).

---

## 5. Data model & migrations (server)

- `projects`, `nodes`, `memberships` — same columns as the daemon migration,
  Postgres types, `parents uuid[]` + GIN index, unique `projects.slug`.
- `users` (AshAuthentication) + `tokens` (hashed personal access tokens).
- **Sync bookkeeping** (server-only): a monotonic cursor for pulls. Options
  (open decision):
  1. a `bigserial` `seq` column on `nodes` (server-only companion schema), or
  2. an `inserted_at` timestamp on `nodes` with a `(inserted_at, id)` tuple
     cursor, or
  3. a dedicated `sync_events` table.
  Recommendation: **1** — simplest stable ordering, and Postgres-specific so it
  stays out of the shared `Node` schema.
- Optional: `cloud_id`/`local_id` correspondence is tracked daemon-side (§7), so
  the server stores no local ids.

---

## 6. Git object transfer (shared)

Add to `Cadence.Shared.GitStore`:
- `objects_from/2` (`GitStore, commit_sha`) → a map/list of
  `%{sha, type, data}` for the commit plus every reachable tree/blob (depth-first
  over `read_tree`).
- `import_objects/2` (repo, objects) → writes raw objects (validating that each
  `sha` equals the content hash) — idempotent, content-addressed.
- Optionally `has_object?/2`.

Wire format on the sync channel: `data` is `Base.encode64(raw_object_bytes)`
(the on-disk zlib form is reconstructed by `GitStore.write_object/3`, which is
currently private — expose a `write_raw/3`). Phase 7 adds an existence handshake
so clients stop re-pushing; for 2b, send all objects per node (dedup by the
content-addressed store).

---

## 7. Daemon: ledger + client

New modules (spec §5.2):
- `Cadence.Daemon.SyncLedger` (GenServer, persistent): per-project pull cursor and
  the `local_node_id ↔ cloud_node_id` mapping. Backed by SQLite (new table
  `sync_ledger`, or nullable `cloud_id` on `nodes` + a `sync_cursors` table).
  Rehydrates pending work on boot.
- `Cadence.Daemon.SyncClient` (`Req`): push/pull with bearer token, timeouts, and
  retry/backoff; reads `CAD_SERVER_URL` / `CAD_AUTH_TOKEN`.
- `Cadence.Daemon.Sync` context: `push_pending/1`, `pull/1`, `sync/1`
  (best-effort, offline-tolerant).

Integration:
- After a successful local commit, enqueue the node for push (async; never block
  the commit). A node with `cloud_id == nil` is pending.
- On pull, import remote nodes' Git objects into the local store, insert sibling
  `Node` rows, and update membership prefs (§10.5).
- Boot: `SyncLedger.rehydrate/0` flushes pending pushes and resumes the cursor.

---

## 8. Endpoints & payloads

All JSON, matching the existing `Cadence.Shared.Sync.*` structs (§10.6).

- `POST /sync/nodes` — body `%{nodes: [%{local_id, git_objects, metadata}]}`
  (`PushNodes`). Server: verify membership, import objects, insert nodes
  (parents resolved via the request's `local_id → cloud_id` map plus already-known
  nodes), broadcast, respond `PushNodesResponse` with `mappings`.
- `GET /sync/nodes?since=<cursor>` — (`PullNodes`/`PullNodesResponse`) returns
  nodes created after the cursor **that the user can see**, plus a new cursor.
- `POST /sync/preferences` — `%{project_id, active_heads, session_pointer}`
  (`PushPreferences`); upserts the caller's `Membership`. Pulled as part of the
  node pull response or a companion endpoint (open decision).
- `GET /health`.

Error semantics: 401 unauthenticated; 403 not a member; 422 malformed/unknown
parent; 200 with per-node errors inside the response for partial batches
(open decision: fail-fast vs per-item).

**Conflict handling (§10.4):** if the cloud already has a child of the same
parent, the pushed node simply becomes a sibling — no merge, no rejection.

---

## 9. Data-flow walkthroughs

- **Offline commit → reconnect:** commit is local and durable; node queued in the
  ledger; on reconnect `SyncClient.push_pending` sends it; server returns a
  cloud id; ledger records the mapping.
- **Machine B resume:** B pulls since its cursor, imports objects, inserts nodes;
  pulls the user's preferences and moves its session pointer (§10.5).
- **Same-parent divergence:** A and B both spawn from `parent`; whichever pushes
  second lands as a sibling; the DAG absorbs it (no “branch” concept).

---

## 10. Config (env)

Daemon (spec §12.6 already lists the first two):
- `CAD_SERVER_URL` (required for sync; absence ⇒ offline mode)
- `CAD_AUTH_TOKEN` (required for sync)
- add: `CAD_SYNC_ENABLED` (default true), `CAD_SYNC_PUSH_INTERVAL_MS`,
  `CAD_SYNC_RETRY_BACKOFF_MS`, `CAD_SYNC_TIMEOUT_MS` (exists).

Server: the §12.5/§12.6 set (`CAD_PHX_HOST`, `CAD_SECRET_KEY_BASE`,
`CAD_DATABASE_URL`, …). Everything read in `config/runtime.exs`; no secrets in
source (`~/.config/cadence/env`).

---

## 11. Testing strategy

- **shared:** `GitStore.objects_from/2` + `import_objects/2` round-trip on a temp
  store (import into an empty store, assert equivalence); `write_raw/3`.
- **server:** `Phoenix.ConnTest` for `/sync/*` — auth rejection (401), non-member
  (403), push→pull round-trip, sibling/conflict case, preferences upsert.
  Postgres via a test database (`CAD_DATABASE_URL` in `config/test.exs`);
  AshAuthentication flows covered at the resource level (no live OAuth).
- **daemon:** `Bypass` to stub the server; `SyncClient` retry/backoff;
  `SyncLedger` persistence + rehydrate; end-to-end local commit → push → pull as
  a sibling. No test hits a real server or LLM.
- AGENTS: every public `cadence_shared` function gets a test.

---

## 12. Milestones (one deliverable per session)

1. **2b-1 — Server scaffold + auth.** `mix.exs` deps, `Repo`, `Endpoint`,
   `/health`, migrations (`projects`/`nodes`/`memberships` + `users`/`tokens`),
   `AuthPlug`, token verification, server test harness. *Acceptance:* `GET
   /health` 200; protected route 401 without/with-bad token, 200 with a valid
   seeded token.
2. **2b-2 — Object transfer + node push/pull.** `GitStore` object API;
   `POST /sync/nodes` (import + insert + map) and `GET /sync/nodes?since=`
   (cursor + GIN-indexed parent queries); server tests for round-trip and
   siblings. *Acceptance:* push a daemon-built DAG, pull it back on a clean repo,
   trees identical.
3. **2b-3 — Daemon ledger + client.** `SyncLedger`, `SyncClient`, enqueue-on-
   commit, pull-into-local, boot rehydrate; Bypass tests. *Acceptance:* two
   daemon instances converge via a stub server; offline commits flush on
   reconnect.
4. **2b-4 — Preferences + broadcast + resilience.** `PushPreferences` both ways,
   PubSub broadcast on write, retry/backoff, partial-batch semantics.
   *Acceptance:* session pointer/active heads travel A→B; broadcast fires.

---

## 13. Risks / open decisions

- **Token issuance** for daemons (CLI `mix` task vs. seeded token vs. a
  token-create endpoint behind OAuth). Blocks 2b-1 acceptance.
- **Cursor representation** (`bigserial seq` vs. `(inserted_at, id)` vs.
  events table) — server-only, but must be stable under concurrent writes.
- **Batch semantics**: fail-fast vs. per-item errors in `PushNodesResponse`.
- **Preferences transport**: folded into the node pull response vs. its own
  endpoint/cursor.
- **Object payload size**: base64 inflates by ~33%; consider batch limits and
  (later) negotiation. Not a blocker for 2b.
- **Parent resolution on push**: a node's parent may not exist server-side yet
  (e.g., pushed out of order). Decide: require parents first (topological batch
  order) or accept forward references resolved on a later push.
- **Auth scope**: per-user vs. per-project tokens.

Update spec §16 with the durable ones once decided.

---

## 14. Spec touch-ups needed

- §10.6: document the Git-object wire format (`Base.encode64` raw) and the
  preferences transport choice.
- §12.6: add the new daemon sync tunables and confirm the server set.
- §5.2: flip `SyncLedger`/`SyncClient` from “planned” to actual once 2b-3 lands.
- §16: add the token-issuance and cursor-representation decisions.
