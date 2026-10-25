# Phase 4 prep — Unions, proposals & review

> Status: **planning only; no code.** `docs/spec.md` §6.5, §6.6, and §13 remain
> canonical. This is the cold-start handoff for Phase 4.

## 0. Start here

1. Read `docs/progress.md`, this brief, then spec §6.5/§6.6/§13/§16.
2. Resolve the decisions in §5. **Do not start 4a until they are approved.**
3. Implement 4a (proposal schema/context), then 4b, then the review UI. Do not
   invert that order.
4. End the first session with a clean migration + context tests, even if no UI
   exists yet.

## 1. Goal

Turn union/meld into a reviewed server-side flow:

- a proposal entity for pending melds and promotions,
- a server-side meld worker with AI assistance,
- approve/reject by authorized reviewers,
- shareable proposal links (view only; no conversation threads),
- broadcast/pull so connected clients converge,
- no auto-promotion and no approval UI before the backend exists.

## 2. Current verified state

- Shared `GitStore` (objects, trees, commits, import/walk), `DAG` depth/edges,
  and sync object transfer are complete.
- Server Postgres models: `Project`, `Node`, `Membership`; auth via
  AshAuthentication; roles are owner/trusted/viewer; `approver` is a legacy-ish
  boolean on memberships.
- Web project home, DAG, repo browser, owner pinning, member read panel, and
  owner/trusted raw view are complete (Phase 3).
- No meld worker, proposal table/context, review routes, or union prompt exists.
- `axiom_ai`/DeepSeek is the existing LLM client; prompts live in
  `cadence_shared/priv/prompts/`.
- Web pinning is server-side only; the daemon does not receive pinned-flag
  updates yet (spec §16).

## 3. Session plan

| Session | Slice | Deliverable | Exit criteria |
|---|---|---|---|
| 1 | 4a-1 | Proposal schema + migration + `Proposals` context | Create/list/fetch/transition tested; roles enforced |
| 2 | 4a-2 | Proposal JSON/route + shareable token | Stable URL; unauthorized access tested |
| 3 | 4b | Meld worker + prompt + validation guard | Mocked LLM; pending proposal produced; no auto-`functioning` |
| 4 | 4c | Review UI + approve/reject + shareable page | Owner/approver flow; idempotent approval; viewer denied |
| 5 | 4d | Broadcast/pull + daemon convergence | Two-client + offline-daemon tests; pin propagation resolved |

4a is the only slice that should be started before the decisions in §5 are
settled. 4b/4c depend on the proposal representation; 4d depends on approval.

## 4. Scope

### 4a — Proposal model + API/context

**First-session checklist**

- Add server-only `Cadence.Server.Proposal` + `Proposals` context (do not put
  this in `cadence_shared`; daemons do not consume proposals).
- Migration `create_proposals`: `token` (unique), `project_id`, `proposer_id`,
  `kind`, `parent_ids uuid[]`, `result_tree_sha`, `meld_commit_sha`, `status`,
  `reviewer_id`, `decided_at`, `created_at` (+ indexes on project/status/token).
- State machine: `pending → approved | rejected`; terminal states immutable;
  repeated approval/rejection is idempotent.
- Context functions: `create/2`, `list/1`, `get_by_token/1`, `approve/3`,
  `reject/3`.
- Role checks at the context boundary or a dedicated policy module; owner and
  trusted-with-`approver` may decide; trusted may propose; viewer may not.
- Tests: validation, invalid parents, duplicate approval, wrong project,
  unauthorized roles, token lookup.
- No UI, worker, or daemon changes in 4a-1.

**Share-link slice (4a-2)**

- Add a stable random URL-safe `token` (not the raw row ID) with a unique index;
  route `GET /proposals/:token` and the minimal JSON/HTML payload.
- Apply the proposal-visibility decision (public vs authenticated); if public,
  reuse the Phase 3 filtering rules for any rendered content.
- Tests: unknown token, wrong project, unauthorized access, stable token across
  reads, no leakage of private proposal metadata.
- Do not build the review UI in 4a-2; that is 4c.

### 4b — Meld worker + validation guard

- Server-side worker: validate parents/membership, fetch trees, run the AI meld
  prompt, materialize the resulting tree/commit, create a pending meld proposal.
- Prompt in `cadence_shared/priv/prompts/`; record provider/model/prompt version.
- Validation policy: **do not auto-promote to `functioning`**. Decide whether a
  meld starts `in-progress` and only approval promotes/pins it, or a future
  test runner sets `functioning`.
- Failure handling: AI error, malformed output, missing objects, conflicts.
- Tests with a mocked LLM (no real API calls).

### 4c — Review UI + shareable link

- Review page/live view: parents, resulting tree/diff, flags, proposer,
  status, approve/reject buttons.
- Shareable link stable and viewable by the intended audience.
- Server-side authorization on every action; no hide-in-HTML authorization.
- After approval: create/attach the meld node, promote/pin as decided, and
  broadcast.
- Tests: owner/trusted/approver/viewer paths, CSRF/event injection, idempotent
  approval, rejected re-submission policy.

### 4d — Convergence + daemon integration

- Broadcast proposal/meld events; clients refresh.
- Ensure daemons pull the new meld node and can display it.
- Resolve the web-pin propagation gap if promotion should be visible locally.
- Tests: two-client convergence, offline daemon then pull, duplicate approval.

## 5. Decisions needed before building

1. **Proposal model:** single approver vs quorum; can a rejected proposal be
   re-submitted; who is the reviewer of record?
2. **Promotion target:** does approval set `pinned`, `functioning`, or a
   distinct protected marker? (§16)
3. **Meld flag/validation:** without Phase 6 actions there is no test runner.
   Recommended: AI meld starts `in-progress`; approval promotes/pins; never
   auto-`functioning`. Confirm.
4. **Meld agent:** model, prompt version, output format, retry/rate limits.
5. **Proposal visibility:** public shareable view vs authenticated-only.
6. **Pin propagation:** how daemons learn about web pins/promotions (sync field,
   update message, or pull-side merge) before promotion is useful locally.
7. **Parent semantics:** meld proposals reference existing parent nodes; the
   resulting commit/tree may be stored before approval or created on approval.

## 6. Security and correctness constraints

- Only approval moves state; proposing never moves another user's pointer.
- AI output is reviewable and reversible; never the final authority.
- Meld flag and promotion are separate: approval moves the line, validation sets
  the flag (§6.6).
- Shareable links must not expose private proposals or raw secrets to
  unauthorized viewers; reuse the Phase 3 filtering/raw-view rules where
  applicable.
- Approval must be idempotent and race-safe.
- Do not log proposal content, tokens, or raw secrets.

## 7. Tests / verification

- Server context tests for proposal state machine and permissions.
- Meld worker tests with a mocked LLM and fixture trees.
- LiveView/controller tests for review pages and shareable links.
- Sync/convergence tests for a daemon pulling the approved meld.
- Full suite plus `MIX_ENV=prod mix compile --warnings-as-errors`.

## 8. Out of scope

- Docker actions (Phase 6).
- Doc automation (Phase 5).
- Storage repack/negotiation (Phase 7).
- Inline review comments/threads; Cadence hosts the view, not the conversation.
