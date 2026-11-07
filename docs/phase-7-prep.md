# Phase 7 — Storage Engineering

**Spec:** §13 Phase 7, §15 (principles 1/5/7), §10.2/§10.6 (push + wire
format), §12.6 (env contract), §16 ("Storage repack trigger").
**Status:** 7a is complete (2026-11-07). 7b (repacker) and 7c (existence
handshake) are planned but not implemented.

## Goal

Two independent, lossless storage wins:

1. **Server-side repack.** Loose objects become Git packfiles with delta
   compression, written and read by `Cadence.Shared.GitStore`. Reads are
   transparent: every existing caller keeps using `read_blob/read_tree/
   read_commit/objects_from/walk_blobs/has_object?`. History is never pruned.
2. **Sync existence handshake.** Before a push, the daemon asks which object
   SHAs the server already holds and omits them from `git_objects`, so retries
   and re-pushes move metadata instead of megabytes.

## Verified starting state

- `GitStore` implements loose objects only (`objects/<2>/<38>`); `init/2`
  creates `objects/pack` but nothing ever writes or reads it. The moduledoc
  explicitly says "no packfiles".
- `has_object?/2` checks only the loose path, so it cannot answer once objects
  are packed.
- Reads (`read_blob/2`, `read_tree/2`, `read_commit/2`) go straight to the
  loose file; `objects_from/2` and `walk_blobs/3` call those, so making the
  three read primitives pack-aware covers every caller (repository browser,
  diffs, melds, scans, actions staging, pull encoding).
- Writes (`write_object/3`) are idempotent loose writes with no locking.
- Push sends the full reachable object set for every node;
  `Sync.push_nodes/2` imports idempotently and re-validates everything. A
  re-push after a rolled-back transaction resends every object.
- No storage config exists; no background storage job exists; no new dependency
  is required (pure Elixir + OTP `:zlib`/`:crypto`).
- Server tests need Postgres on `localhost:55432`; daemon/shared tests do not.

## Proposed slices (one deliverable per session)

### 7a — pack primitives + transparent reads (shipped 2026-11-07)

- `Cadence.Shared.GitStore.Pack`: Git pack v2 encoder (full entries and
  ofs-delta/ref-delta), decoder, and delta apply/build.
- `Cadence.Shared.GitStore.Pack.Index`: idx v2 writer/reader (fanout, sorted
  SHAs, CRC32, 32/64-bit offsets, both checksums), SHA → offset lookup.
- `GitStore` integration: `read_object/2` falls back to packs,
  `has_object?/2` consults packs, `init/2`/`open/2` unchanged for callers.
- A small index cache process (`Cadence.Shared.GitStore.Cache`, ETS) started by
  both apps so a walk does not re-parse an index per object. Invalidation on
  pack rename is explicit; any stat change also invalidates.
- `GitStore.pack_objects/2` (or `Pack.write/3`) writes a pack atomically from a
  list of object SHAs plus a naming/verification result. 7a does **not** remove
  loose objects and does **not** run automatically.
- No server/daemon behavior changes; no config keys beyond the cache (none).
- Tests: encoder/decoder round-trip, both delta kinds, malformed/truncated
  packs, checksum mismatch, mixed loose+pack store, `walk_blobs`/`objects_from`
  through a pack, idx lookup, deep delta chains, cache invalidation.

Shipped as `GitStore.Pack`, `GitStore.Pack.Index`, `GitStore.Pack.Delta`,
`GitStore.Cache` (plus `Cadence.Shared.Application`), and `pack_objects/3`,
`packs/1`, `loose_objects/1`, `invalidate_cache/1` on `GitStore`. Reads stay
loose-first; the cache validates each pack's trailer against its index and
skips a mismatched pair. 54 new shared tests; 994 total green (306 shared + 188 daemon + 500 server).

### 7b — server repacker job

- `Cadence.Server.Storage` + `Repacker` (supervised `GenServer` or `Task` under
  a dedicated supervisor) with bounded concurrency (1 per project, small global
  cap).
- Trigger per the decision below; manual `mix cadence.repack` task; per-project
  advisory lock so two nodes/runs cannot repack the same store concurrently.
- Safety: pack into a temp file in `objects/pack`, write the idx, verify every
  object (SHA + type) by reading **through the pack**, fsync both files, rename,
  and invalidate the cache. **Do not delete loose copies in the run that wrote
  the pack.** A later repack/sweep re-verifies that the pack is present, its
  trailer matches, and every covered SHA still reads, and only then unlinks the
  loose files. OTP cannot fsync a directory, so this deferred-deletion rule is
  what makes the rename durable before data is removed: a power loss after the
  pack run leaves loose copies intact (the next run re-verifies), and a crash
  during deletion still leaves the pack. A `.tmp` pair left by a crash is
  invisible to discovery and is swept on the next run.
- Config (§12.6): `CAD_REPACK_ENABLED`, `CAD_REPACK_MIN_OBJECTS`,
  `CAD_REPACK_MIN_BYTES`, `CAD_REPACK_INTERVAL_MS`, `CAD_REPACK_MAX_PACK_BYTES`
  (split oversized sets), following the decision below.
- Metrics/logs are shape-only (pack name, object count, bytes, delta ratio);
  no object content is logged.

### 7c — sync existence handshake

- `POST /sync/objects/exists` (bearer PAT, writable roles, project-scoped):
  `%{project_id, shas: [40-hex]}` → `%{present: [40-hex]}`. Capped; invalid
  SHA/unknown project/role map to the existing 4xx shapes.
- Daemon `SyncClient.objects_exist/2`; `push_batch/3` collects the batch's
  unique object SHAs, asks once, and drops present objects per node before
  encoding. Any handshake failure (timeout/5xx/429) falls back to the current
  full push; the handshake never blocks or fails a push. A server 422 after a
  filtered push is treated as a handshake miss: retry the batch once with all
  objects, then surface the normal node error.
- The node commit's metadata is always sent; only `git_objects` shrinks.
  Server `ensure_complete/2` remains the authority, so a wrong/raced answer is
  a server 422, not corruption. The route answers from
  `GitStore.present_shas/2` (index membership), not one `has_object?/2` call
  per SHA.
- Config: `CAD_SYNC_EXISTS_LIMIT` (default 5000); over-cap batches send all
  objects (or chunk — decide in the slice plan).
- Spec §10.2/§10.6 updated with the route, request/response, cap, and fallback.

### 7d — verification / closeout (fold into 7b/7c if small)

- Multi-pack reads, index growth, delta-chain depth cap, repack of an already
  packed store (new loose objects only), and a real-store smoke on the demo
  stack.

## Decisions to confirm before implementation

| # | Question | Recommendation |
|---|---|---|
| P7-D1 | Repack trigger (§16) | **Approved 2026-11-07.** Threshold after a successful push (best-effort, async) plus a periodic backstop and a manual mix task. Defaults: 1,000 loose objects or 64 MiB per project, interval 6 h, concurrency 1. |
| P7-D2 | Loose-object deletion | **Approved 2026-11-07.** Delete a loose file only after the pack containing it is verified readable and renamed into place. "Non-destructive" means no history/unreachable-object pruning, not "keep two copies forever." |
| P7-D3 | Handshake shape | Dedicated `POST /sync/objects/exists`, one request per push batch, full-push fallback on any error, 5,000-SHA cap. |
| P7-D4 | Format fidelity | **Approved 2026-11-07 and shipped in 7a.** Real Git pack v2 + idx v2 (SHA-1, zlib, ofs/ref-delta), no new dependency, no thin packs. Interop remains a non-goal (§14) but the bytes are standard. |
| P7-D5 | Slice order | **Approved 2026-11-07.** 7a → 7b → 7c. 7a is invisible (no behavior/config change) and gates the rest because `has_object?` must answer from packs. |

## Test matrix

| Area | File | Cases |
|---|---|---|
| Pack codec (7a) | `pack_test.exs` | empty/single/multi object packs; full entries; ofs-delta; ref-delta; deep chain; delta larger than full falls back; truncated header/body; bad zlib; size mismatch; trailer checksum; unknown type |
| Pack index (7a) | `pack_index_test.exs` | empty index; fanout counts; sorted lookup; 32-bit offsets; large-offset table; CRC32; pack/index checksums; corrupt magic/version/length |
| GitStore integration (7a) | `git_store_test.exs` (extend) | `read_*` from pack only; mixed loose+pack; `has_object?`; `objects_from`; `walk_blobs`; `diff_trees`; cache invalidation after a new pack |
| Repacker (7b) | `storage_repacker_test.exs` | threshold gate; pack+idx written; every object readable after loose removal; crash/temp-file ignored; concurrent writer safe; idempotent second run; oversized set split; failure leaves loose intact |
| Handshake (7c) | `sync_objects_exists_test.exs`, `sync_test.exs` | present/absent; mixed batch; cap; malformed SHA; non-member; unknown project; daemon drops present objects; fallback on 5xx/timeout/429; no objects unchanged |

## Acceptance

**7a:** a store whose objects live only in a pack serves `read_blob`,
`read_tree`, `read_commit`, `objects_from`, `walk_blobs`, `list_path`,
`diff_trees`, `read_path`, and `has_object?` identically to a loose store;
a corrupt pack degrades to `nil`/`{:error, …}`, never a crash; both delta
kinds and deep chains resolve; `mix format --check-formatted`, dev + prod
compile with warnings as errors, and shared/daemon/server suites pass.

**7b:** a project above the threshold is repacked in the background; every
object remains readable; loose copies are gone; a failed/aborted run leaves the
store fully readable with loose objects intact; nothing prunes history.

**7c:** a second push of an already-stored node sends no `git_objects` and
still succeeds; a handshake failure falls back to the current full push; the
server never accepts an incomplete node.

## Risks

1. **Format complexity.** Pack v2 + idx v2 are byte-level formats with
   checksums and recursion. Mitigation: pure encode/decode modules with
   round-trip and malformed-input tests, and a hand-built known-bytes fixture.
2. **Delta CPU/memory.** Delta building can be quadratic. Mitigation: fixed
   block matcher with a single base candidate per type group, size caps, and a
   "skip delta if not smaller" rule.
3. **Loose deletion race.** A concurrent push may write while a repack runs.
   Mitigation: pack only a snapshot of SHAs, verify each before deletion, and
   rely on content addressing (a re-written object is identical).
4. **Cache staleness.** A global index cache can miss a pack written by another
   VM/node or serve one removed externally. Mitigation: `pack_objects/3`
   invalidates explicitly, `GitStore` reloads a store once on a packed read
   miss, the cache validates each pack trailer against its index on load, and
   the table is bounded at 1,024 stores. An out-of-process writer cannot clear
   this VM's table directly; the reload-on-miss covers reads, and a resend
   covers the 7c handshake.
5. **Read-path regression.** Every server read now checks packs. Mitigation:
   loose check first (current fast path unchanged), one cached index lookup
   second.
6. **Repack cost.** Packing a large store blocks a scheduler. Mitigation:
   bounded concurrency, `CAD_REPACK_MAX_PACK_BYTES` splits, work in a task.
7. **Disk doubling during repack.** Pack + loose coexist until a later sweep
   verifies the pack and deletes the loose copies (at most one backstop
   interval, 6 h at defaults). Deployment must budget transient 2×
   object-store size; documented.
8. **Unreachable objects are kept.** Repacking packs everything it finds; no GC
   or pruning is added (§15). A future prune needs its own review.
9. **Thin packs / external packs.** Not produced and not supported; a ref-delta
   base must be in the same pack, and an out-of-pack base fails closed
   (`:not_found`).
10. **Multi-pack growth.** Each repack adds a pack; no consolidation yet.
    Bounded concurrency plus the threshold keeps this small; consolidation can
    follow if pack count grows.

## Out of scope

- Garbage collection / unreachable-object pruning.
- Pack consolidation (multi-pack index, pack reuse).
- Client-side (daemon) repacking; Phase 7 is server-side per §13.
- Git protocol interop (`git clone`/`fetch`).
- Postgres WAL/backup changes (§16 separate item).
- The `parents uuid[] → edges` migration threshold mentioned in the same §16
  bullet.
