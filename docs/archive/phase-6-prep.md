# Phase 6 — Docker Actions

**Spec:** §8 (concept, language support, isolation, security), §12.4 (compose
socket proxy), §12.6 (env contract), §12.9 (security notes), §13 Phase 6.
**Status:** 6a, 6b, and 6c complete.

## Goal

A project can ship an `actions/manifest.json` in its repository. Members see
the project's actions; owners/trusted members run one against a chosen node
snapshot in an isolated container, follow the status live, and keep the output
as an artifact attached to that node (captured post-exit).

## Verified starting state

- `Project.docker_image` and `Project.actions_manifest` columns exist but
  nothing populates or reads them. (`actions_manifest` was removed in the
  closeout cleanup; the manifest is read from the selected snapshot.)
- No action/runtime modules exist on the daemon or server.
- `GitStore.read_path/4` reads a single path from a commit tree with a byte cap
  and path-escape guards — the safe way to load a manifest from a snapshot.
- `Cadence.Server.Authorization` already distinguishes `can_view?` (owner,
  trusted, viewer) from `can_manage?` (owner, trusted).
- `ex_docker_api` 1.55.0 (MIT, 2026-06-30) is the approved library (spec §11)
  and targets Elixir 1.18's built-in JSON.
- The demo stack runs, but its compose file has no Docker socket proxy or
  shared action volume yet.

## Decisions (approved 2026-11-06)

| # | Decision |
|---|---|
| D1 | **Snapshot-addressed.** The manifest and the code an action runs are read from the selected node's Git tree, not a server working copy. |
| D2 | **Members see, managers run.** Any member (`can_view?`) sees the action list; only owner/trusted (`can_manage?`) may run one. Anonymous never sees or runs actions. Enforced again at the run boundary in 6b. |
| D3 | **`expose` is parsed, not yet honored.** The manifest flag is validated into the action struct; public visibility semantics are decided in 6c, not silently inferred. |
| D4 | **6a adds no dependency and no containers.** It is manifest validation, config, authorization, a read-only listing, and tests. `ex_docker_api` lands in 6b with a spec §11 version row. |
| D5 | **Sibling-container I/O uses a Docker named volume.** The runner stages a snapshot into a volume mounted by both the server container and the action container; bind mounts from the server's own filesystem are not visible to the host daemon. |
| D6 | **Caps everywhere.** Manifest size/action count are env-tunable; command/description lengths and the name grammar are fixed validation rules. |

## Slices

### 6a — manifest foundation (this session)

- `Cadence.Server.Actions.Manifest`: pure parse/validate of
  `actions/manifest.json`.
- `Cadence.Server.Actions`: `CAD_ACTIONS_ENABLED` gate, snapshot read through
  `ProjectGit.open/1` + `GitStore.read_path/4`, membership check, capped parse.
- `ProjectLive`: read-only "Actions" panel in the node inspector for members;
  hidden when actions are disabled, the manifest is absent, or the snapshot is
  quarantined.
- Config: `CAD_ACTIONS_ENABLED`, `CAD_DOCKER_SOCKET`, `CAD_ARTIFACT_PATH`,
  `CAD_ACTIONS_MAX_MANIFEST_BYTES`, `CAD_ACTIONS_MAX_ACTIONS` in
  `config/runtime.exs` and spec §12.6.
- No `ex_docker_api`, no image build, no execution.
- The manifest is re-read on each node navigation (one bounded blob read, no
  extra query). Snapshots are immutable, so a per-node cache is a possible
  optimization if navigation cost shows up.

### 6b — runner (shipped)

Shipped as `Cadence.Server.Actions.Runs` (prepare/start/execute), `ActionRun`
schema + migration, `Actions.Staging`, `Actions.Artifacts`, an
`Actions.Docker` behaviour with `DockerEngine` (ex_docker_api) and a test fake,
and the demo socket proxy/volumes. Decisions taken during 6b:

- durable `action_runs` rows with lazy stale-run recovery (`:interrupted`);
- shared named volume with per-run `volume-subpath` mounts (Docker ≥ 26), code
  read-only at `/workspace`, output at `/out`;
- `project.docker_image` wins, else root `Dockerfile` → tag
  `cadence-action-<slug>-<sha12>`, else `no_image`;
- `/bin/sh -c <command>`, no network by default (build `RUN` steps separately
  default to `none`), memory/CPU/PID limits, read-only rootfs with a small
  `noexec` `/tmp`, `CapDrop=ALL`, `no-new-privileges`, swap capped to memory;
- TTY log capture (stderr merged) capped and written to
  `<artifact_path>/<run_id>/output.log`; artifacts in `.../artifacts/` (regular
  files only, capped);
- no artifact retention and no per-project concurrency cap (spec §16 deltas).

- Add `{:ex_docker_api, "~> 1.55"}` to `cadence_server`; record the version in
  spec §11.
- Stage the node snapshot into the shared action volume; reuse a
  `project.docker_image` when set, otherwise build and cache
  `cadence-action-<project>-<sha12>` from the snapshot's `Dockerfile`.
- Create/start a container: no network unless the action opts in, CPU/memory
  limits, read-only code mount, writable output dir.
- Capture and persist logs; write artifacts under `CAD_ARTIFACT_PATH/<run_id>`.
- Tests use a fake Docker client; no test talks to a real daemon.
- Demo compose gains `docker-socket-proxy` and the shared action volume.

### 6c — web run experience (shipped)

Shipped as `RunLive.Index` (`/p/:slug/runs`) and `RunLive.Show`
(`/p/:slug/runs/:run_id`), manager-only Run controls on the node action panel,
and `RunArtifactController` for allowlisted downloads. Decisions taken during
6c:

- the panel stays members-only, so `expose` remains parsed but unhonored (§16);
- the run list/detail refresh from the existing
  `{:action_run_updated, project_id, run_id, status}` event; logs are captured
  post-exit, so no partial streaming;
- output is rendered as escaped text with ANSI/control sequences stripped;
- artifact downloads accept only an exact path from the run's recorded
  collection and are served as an attachment;
- each page reuses the member access rule and `Runs` re-authorizes; every
  `handle_event` re-reads the membership.

## Test matrix

| Area | File | Cases |
|---|---|---|
| Manifest parser | `actions_manifest_test.exs` | valid example; missing/invalid JSON; empty actions; caps (bytes, count); bad name/command/description/expose; duplicates; NUL/control chars; unknown keys ignored |
| Actions context | `actions_test.exs` | disabled; missing manifest; too large; invalid manifest; non-member forbidden; viewer may list; manager may list; other project's node |
| Project page | `project_live_test.exs` | member sees name/description/command; anonymous does not; quarantined snapshot hides; no manifest hides; disabled hides |
| Runner (6b) | `actions_runs_test.exs`, `actions_docker_engine_test.exs`, `actions_staging_test.exs` | image reuse/build; limits; no network; log capture; artifact path; failure mapping; request mapping; staging caps |
| UI (6c) | `run_live_test.exs`, `project_live_test.exs` | run control only for managers; forced event refused; raw-view quarantine re-check; run list/detail member-only and live-refreshed; escaped/ANSI-stripped output; artifact download allowlist (nested/space/traversal); disabled deployment |

## Acceptance for 6a

- A node whose tree contains `actions/manifest.json` lists its actions for a
  signed-in member on `/p/:slug/n/:id`.
- Anonymous visitors, quarantined snapshots, and disabled deployments see no
  action panel.
- A malformed or oversized manifest never crashes the public project page.
- `mix format --check-formatted`, dev + prod compile, and the full suite pass.

## Risks

1. **Untrusted code execution.** Actions are project code by definition. The
   socket proxy (allowlisted endpoints), no-network default, resource limits,
   read-only code mount, and `CAD_ACTIONS_ENABLED` are mandatory; 6b cannot
   ship without them.
2. **Sibling volume correctness.** The action container must receive exactly
   the snapshot the member selected, never the server's Git store or another
   project's files. Run dirs are `run_id`-scoped and removed after collection.
3. **Manifest trust.** The manifest is client-pushed content; parsing is strict
   and capped, and a bad manifest is a shape-only error (no panel), never a 500.
4. **Artifact growth.** `CAD_ARTIFACT_PATH` needs retention/quotas; record as a
   delta if 6b does not implement pruning.
5. **Run durability.** An in-memory run registry loses state on restart; a
   durable run table is a 6b decision.
6. **Action volume quota.** `/out` is unbounded while a run executes; the
   deployment must put `CAD_ACTIONS_VOLUME_PATH` on a size-limited filesystem
   (§8.3, §12.9).
