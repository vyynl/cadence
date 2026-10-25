# Phase 3b prep — LiveView project home + repository browser

> Status: **3b-1 implemented; 3b-2 ready for build.** `docs/spec.md`
> §7/§13/§16 are canonical. This brief is the cold-start plan for 3b-1 and
> 3b-2.

## 1. Goal

Replace the 3a static project card with a LiveView project home:

- full read-only DAG on the left (25%),
- node snapshot browser on the right (75%) with file tree, file viewer, and
  rendered README,
- click a DAG node to swap the right pane in place,
- hover a node for a tooltip/highlight only,
- first-load lineage animation from root to the default node, a pulse, then the
  repo pane reveal,
- mandatory public secret filtering so old test/POC nodes cannot leak
  credentials.

Public visitors can browse any node. Authentication is only required for
mutation/control features in 3d.

## 2. Current verified state

- 3a ships `/` (placeholder), `/p/:slug` (static preview card), HTML layout and
  error pages, `Cadence.Server.Portfolio`, and
  `Cadence.Shared.GitStore.read_path/3`.
- `Phoenix.LiveView` 1.2 and `phoenix_html` 4.3 are direct server dependencies,
  but no LiveView module, `/live` socket, or browser asset is wired yet.
- Prebuilt browser bundles exist in the dependencies and can be served directly:
  - `deps/phoenix/priv/static/phoenix.min.js`
  - `deps/phoenix_live_view/priv/static/phoenix_live_view.min.js`
- `AshAuthentication.Phoenix.LiveSession` is available for `current_user` in
  LiveViews.
- `Cadence.Shared.DAG` already provides `depths/1`, `edges/1`, `preview_node/1`,
  and `default_node/2`.
- `GitStore` can read commits/trees/blobs and individual paths; it cannot yet
  list a directory tree for the browser.
- `MDEx` is named in spec §11 but is not a dependency yet.
- Server tests need Postgres on 55432.

## 3. Decisions in force

1. Public sees the **full DAG** and may browse any node's snapshot.
2. Y-axis is topological depth; timestamps live in hover metadata.
3. 3b uses LiveView, not dead views.
4. URLs are nested tree/blob paths.
5. Hover is tooltip + highlight only; it does not change the right pane.
6. Intro animates the default node's ancestor lineage along real edge paths,
   pulses the default node, then fades the rest + repo pane.
7. Public content is filtered server-side, on every event.
8. Review/promotion UI remains Phase 4.

## 4. Architecture

### LiveView and assets

- Endpoint:
  - move `@session_options` above the socket declarations,
  - add `socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info:
    [session: @session_options]], longpoll: false`,
  - serve the prebuilt bundles from dependency priv dirs with `Plug.Static`
    (`/assets/vendor/phoenix.min.js`,
    `/assets/vendor/phoenix_live_view.min.js`),
  - serve `apps/cadence_server/priv/static` at `/assets`.
- Add `apps/cadence_server/priv/static/js/app.js`:
  - read the CSRF meta tag,
  - `new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: ...}})`.
- Layout: CSRF meta tag + the three script tags. Keep the existing inline CSS or
  move it to `priv/static/css/app.css`; no build step.
- Router: add `import Phoenix.LiveView.Router` to `Cadence.ServerWeb.router/0`,
  then an `ash_authentication_live_session :project` block for the project
  routes. `current_user` is assigned when present, otherwise nil.
- Remove the static `GET /p/:slug` controller route; keep `/` until 3c.

### Routes

```text
/p/:slug                            ProjectLive :home   (3b-1)
/p/:slug/n/:node_id                 ProjectLive :node   (3b-1)
/p/:slug/n/:node_id/tree/*path      ProjectLive :tree   (3b-2)
/p/:slug/n/:node_id/blob/*path      ProjectLive :blob   (3b-2)
```

- `handle_params/3` uses `socket.assigns.live_action` to decide home/node/tree/blob.
- Selection/tree/file changes call `push_patch`, so URLs are shareable and
  survive reloads.
- A LiveView patch updates only the right pane; it does not replay the intro.

### Data flow

1. `ProjectLive` resolves the project by slug.
2. `Portfolio` loads nodes and selects the preview node by default.
3. `Cadence.Shared.DAG` supplies depths/edges.
4. `Cadence.ServerWeb.DAGLayout` computes layers, x/y, elbow paths, the intro
   lineage, delays, and the default node.
5. `Cadence.ServerWeb.Components.DAG` renders the SVG.
6. `Portfolio` loads the selected node's snapshot (tree/file/README) through
   `GitStore`.
7. `Cadence.Server.PublicContent` filters the snapshot before it reaches the
   template. Filtering happens before Markdown rendering or highlighting.

## 5. Visual and interaction design

- 25/75 split: DAG rail left, snapshot pane right. On narrow screens, stack the
  DAG above the pane.
- Nodes: `r ≈ 8`, flag colors per spec §7.3, pinned ring, child-flag edge
  strokes. Multi-flag precedence matches the Neovim picker.
- Hover: node scale/glow + CSS tooltip with commit message and flags/pinned.
  No right-pane change.
- Click: select node, update URL, crossfade the right pane (~180ms).
- Right pane home: node header (message, flags, timestamp, short SHA), file tree
  (directories first), README below.
- Directory view: breadcrumb + entries; click drills in.
- File view: breadcrumb, escaped monospace content, line numbers, horizontal
  scroll; no README repetition. Binary/oversize shows a notice.
- Empty project: "No commits yet."; missing README: explicit empty state.

### Intro animation

- Runs on first full page load only.
- Compute the ancestor subgraph of the default node (all parents recursively,
  deduped). Animate those edges in depth order along their real elbow paths;
  animate lineage nodes as their incoming edge lands.
- After reaching the default node's depth, pulse the default node twice.
- Then fade in non-lineage nodes/edges and slide/fade in the right pane.
- Paced by `CAD_DAG_INTRO_MS` (default 1200ms); per-edge/per-node delays are
  values passed to CSS custom properties. The repo reveal follows the pulse.
- `prefers-reduced-motion: reduce` disables the sequence and renders final state.
- Large DAGs animate only the lineage; never every edge.

Suggested timing split:

- 0–55% of `CAD_DAG_INTRO_MS`: lineage draw + node reveals.
- 55–95%: default-node pulse (2 × 240ms).
- 95%+: remaining graph + right pane fade/slide.

## 6. Repository browser data APIs

### `GitStore.list_path/4`

```elixir
list_path(repo, commit_sha, path, opts \\ [])
# => {:ok, [%{name, type, path}]} |
#    {:error, :not_found | :not_a_directory | :unsafe_path}
```

- Reuses `split_path/1`, `find_entry/3`, `read_tree/2`.
- Sorts directories before files, then by name.
- Rejects absolute/`..`/empty-segment/backslash paths.
- `opts[:max_entries]` caps the result and reports truncation separately.
- Tests: root, nested, missing, file-as-directory, unsafe paths, cap.

Existing `read_path/3` handles files with `:too_large` and path rejection.

### `Cadence.Server.Portfolio`

Add:

- `node_for_project/2` — validate a node belongs to the project.
- `snapshot/3` — node header + root entries + README + hidden count.
- `list_dir/4` — directory entries for a path.
- `read_file/4` — content, size, binary flag; applies caps.
- `read_readme/3` — README resolution + content.

Keep public filtering in `Cadence.Server.PublicContent`, called by these
functions, not in templates.

### `Cadence.Server.PublicContent`

- `sensitive_path?/1` — basename denylist.
- `filter_entries/1` — returns visible entries + hidden count.
- `redact/1` — text → `{redacted_text, findings}` where findings are pattern
  names/counts only.
- `redact_message/1` — for DAG tooltip/node header.
- `quarantine?/1` — whether a node snapshot is blocked entirely because a
  high-confidence secret was found anywhere in it.
- `binary?/1` — NUL / invalid UTF-8 guard.
- `blocked_file?/2` — path or private-key block.
- Never log values or content.

## 7. Secret filtering rules (first version)

Path denylist (case-insensitive basenames):

```text
.env, .env.*, *.pem, *.key, *.p12, *.pfx, *.jks, *.keystore,
id_rsa*, id_dsa*, id_ecdsa*, id_ed25519*, *.ppk,
.npmrc, .pypirc, .netrc, .git-credentials,
credentials*, secrets.*, *.secret, *.secrets
```

`*.env.example` is allowed but scanned; if it looks like it contains a real
value, it is redacted.

Content patterns (non-exhaustive, high confidence):

- private-key blocks (`-----BEGIN ... PRIVATE KEY-----`)
- AWS access key IDs (`AKIA...`)
- GitHub/GitLab tokens (`ghp_`, `github_pat_`, `glpat-`)
- Slack tokens (`xox[baprs]-`)
- Stripe live keys (`sk_live_`, `rk_live_`)
- OpenAI/Anthropic keys (`sk-`, `sk-ant-`)
- Google API keys (`AIza...`)
- JWTs (`eyJ...`)
- generic assignments of `api_key|secret|token|password|client_secret` to a
  value of meaningful length

Behavior:

- Sensitive path → file omitted from the public tree; generic hidden count.
- Private-key block → file blocked; generic "hidden for security" notice.
- Other pattern matches → values replaced with `[REDACTED]`; surrounding text
  preserved.
- **Node quarantine** → if a high-confidence secret is detected anywhere in the
  node's snapshot (including files that would otherwise be redacted), the whole
  public repository pane is hidden with a generic "snapshot hidden for review"
  notice. The DAG node/flags remain visible. No tree, file, or README content is
  returned for a quarantined node.
- Binary → metadata only, no content.
- Commit message → redacted before tooltip/node header.
- Public and default authenticated renders are filtered; explicit raw reveal is
  3d.
- Best-effort only; spec says owners must rotate leaked secrets. False-positive
  overrides are deferred.

## 8. Configuration

Add to `config/runtime.exs` and `.env.example`:

| Variable | Default | Purpose |
|---|---|---|
| `CAD_DAG_INTRO_MS` | `1200` | Intro animation duration |
| `CAD_LIVE_VIEW_SALT` | `CAD_SECRET_KEY_BASE` | LiveView static-token signing salt |
| `CAD_FILE_MAX_BYTES` | `524288` | File viewer content cap |
| `CAD_README_MAX_BYTES` | `262144` | README content cap |
| `CAD_TREE_MAX_ENTRIES` | `1000` | Directory listing cap |

No secret-filter disable switch. Filtering is mandatory for anonymous renders.

## 9. Files expected to change

### 3b-1

- `apps/cadence_server/lib/cadence/server_web/endpoint.ex`
- `apps/cadence_server/lib/cadence/server_web/router.ex`
- `apps/cadence_server/lib/cadence/server_web.ex`
- `apps/cadence_server/lib/cadence/server_web/components/layouts/app.html.heex`
- `apps/cadence_server/lib/cadence/server_web/components/dag.ex`
- `apps/cadence_server/lib/cadence/server_web/dag_layout.ex`
- `apps/cadence_server/lib/cadence/server_web/project_live.ex`
- `apps/cadence_server/lib/cadence/server/public_content.ex` (message redaction)
- `apps/cadence_server/priv/static/js/app.js`
- `apps/cadence_server/priv/static/css/app.css`
- `apps/cadence_server/lib/cadence/server/portfolio.ex`
- `apps/cadence_server/mix.exs` (`lazy_html`, test only)
- `config/runtime.exs`, `config/test.exs`, `.env.example`
- remove `project_controller.ex` / `project_html.*`
- tests: `dag_layout_test.exs`, `project_live_test.exs`,
  `public_content_test.exs`

### 3b-2

- `apps/cadence_shared/lib/cadence/shared/git_store.ex` (+ tests)
- `apps/cadence_server/lib/cadence/server/portfolio.ex` (+ tests)
- `apps/cadence_server/lib/cadence/server/public_content.ex` (extend to files,
  paths, quarantine; + tests)
- `apps/cadence_server/lib/cadence/server_web/project_live.ex`
- `apps/cadence_server/lib/cadence/server_web/components/repo_browser.ex`
- `apps/cadence_server/lib/cadence/server_web/components/file_view.ex`
- `apps/cadence_server/mix.exs` (`mdex`)
- `config/runtime.exs`, `.env.example`
- tests: extended `public_content_test.exs`, `repo_browser_test.exs`,
  extended `project_live_test.exs`

## 10. Tests and acceptance

### 3b-1 acceptance

- `GET /p/:slug` initially renders the full DAG and project shell.
- LiveView connects; clicking a node patches the URL and right-pane metadata.
- Hover tooltip markup shows message + flags.
- Intro attributes/classes exist for the default lineage; reduced-motion path
  renders final state.
- Pure layout tests cover linear, branch, meld, wide/wrap, lineage, delays.
- Public and member LiveViews both mount; authorization is server-side.
- Format/compile/full suite/prod compile clean.

### 3b-2 acceptance

- Root tree lists directories first then files; directories drill in.
- File view shows escaped content/line numbers; binary/oversize show notices.
- README renders through `MDEx`; missing README is explicit.
- Nested tree/blob URLs survive reload and `push_patch`.
- Sensitive paths are absent from public HTML; detected secrets never appear in
  response bodies; commit messages are redacted.
- Direct LiveView events cannot bypass filtering.
- Caps are enforced and reported.
- Full suite/prod compile clean.

## 11. Open questions before build

1. **Syntax highlighting:** plain escaped code (recommended for 3b-2) vs a
   server-side highlighter (new dependency in §11) vs a vendored client-side
   highlighter working on redacted content.
2. **Member raw view:** is the 3d explicit reveal acceptable, or should
   authenticated members also see filtered content by default?
3. **Public flags:** keep `broken`/`sandbox` visible publicly (current plan) or
   hide those nodes while keeping the rest of the DAG public?
4. **Intro on large DAGs:** confirm lineage-only animation is the default.
5. **Secret pattern review:** confirm the first denylist/pattern set; additions
   can follow.

## 12. Risks

- Secret scanning is best-effort and cannot guarantee detection of obfuscated
  credentials. Rotate anything ever committed.
- Full public DAG exposes historical snapshots; this is a deliberate visibility
  change from the earlier preview-only decision.
- LiveView events are a bypass surface; filtering must be re-applied on every
  event and in the context, never in the template.
- Serving dependency JS bundles directly couples the page to those files
  remaining in the dependency priv directories; pinning the dependency versions
  mitigates this.
- LiveView node/file patches must not replay the intro; verify DOM persistence.
- Large trees/readmes and large DAGs need caps and lineage-only animation to
  stay responsive.
