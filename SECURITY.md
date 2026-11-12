# Security Policy

Cadence is a local-first, self-hosted source control system. A server stores
code and serves it publicly, a daemon watches working trees and holds a local
socket API, and the server can run Docker actions. Security reports are welcome
and are handled privately.

## Supported versions

| Version | Supported |
|---|---|
| 1.x (current: 1.0.0) | Yes |
| < 1.0 | No |

Fixes land on the latest 1.x release and on `master`. There are no maintained
backport branches, so if you build from a commit, include the commit SHA in your
report.

## Reporting a vulnerability

**Do not open a public issue, discussion, or pull request for a vulnerability.**

Report privately through GitHub Security Advisories:

1. Open the repository on GitHub.
2. Go to **Security** → **Advisories** → **Report a vulnerability**.
3. Describe the issue in the advisory form.

No security email address is published for this project. Do not send reports to
addresses found in commit metadata — the default Git identity is the placeholder
`cadence@local`, and personal addresses are not a supported security channel.

If the advisory form is not available yet (private reporting has not been
enabled on the repository), open a public issue that says only that you need a
private security channel. Do not put details, payloads, or reproduction steps
in it.

## What to include

- **Component:** `cadence_server`, `cadence_daemon`, `cadence.nvim`, or the
  shared code (`cadence_shared`: schemas, sync protocol, Git object store, LLM
  client).
- **Version and deployment:** `1.0.0` or a commit SHA, and whether it runs from
  a source checkout, a daemon release, the `docker compose` demo stack, or the
  production compose stack.
- **Relevant configuration:** the `CAD_*` variables involved, with secrets
  removed — in particular whether the server is publicly reachable, whether
  actions are enabled (`CAD_ACTIONS_ENABLED`), and whether sync is configured.
- **A minimal reproduction:** the request/response, socket call, repository
  shape, node or proposal token, or command sequence that triggers the issue.
- **Impact:** expected versus actual behavior, and what an attacker gains (data
  disclosure, privilege escalation, code execution, denial of service, ...).
- **Evidence:** logs or stack traces with tokens, cookies, `CAD_SECRET_KEY_BASE`,
  `CAD_LLM_API_KEY`, `CAD_AUTH_TOKEN`, and personal data redacted.
- **Credit and follow-up:** whether you want credit in the advisory, and
  whether you can test a fix.

Do not include live credentials. Rotate any token you suspect has leaked.

## Scope

In scope:

- **Server** (`cadence_server`): the public portfolio, DAG, repository browser,
  proposal pages, and review UI; authentication and personal access tokens;
  the `/sync/*` API, rate limiting, and body limits; the meld/union pipeline;
  secret detection, quarantine, and incident handling; action runs and artifact
  downloads; the Docker socket-proxy boundary.
- **Daemon** (`cadence_daemon`): the Unix socket API, file watcher, commit and
  doc queues, local SQLite state, and the sync client.
- **Neovim plugin** (`cadence.nvim`): command handling and the socket client.
- **Object store** (`Cadence.Shared.GitStore`, plus the server's
  `Cadence.Server.Storage`): loose and pack v2/idx v2 parsing and writing, delta
  application, pack indexes, the object cache, and the repacker — including any
  path that reads outside the store, exhausts memory, or corrupts objects from a
  crafted repository.
- **Sync protocol:** project provisioning, push and pull, the existence
  handshake, union submission, and conflict handling between daemon and server.
- **Actions:** `actions/manifest.json` parsing, snapshot staging, container
  limits, socket-proxy allowlists, log handling, and artifact collection.

Out of scope:

- Issues that require an already-compromised host account, root on the server,
  or control of the Docker daemon.
- The four accepted hackney 1.25.0 advisories recorded in `.mix_audit.ignore`
  and documented in [the 2026-11-11 audit](docs/audit-2026-11-11.md) and
  [spec §16](docs/spec.md#16-open-decisions). They are ignored by exact GHSA ID,
  not by package. Report them again only with a concrete exploit path through
  Cadence's usage (the only host hackney calls is the operator's
  `CAD_LLM_BASE_URL`).
- Known limitations that are already documented as deployment prerequisites
  rather than defects — for example, action containers share the host user
  namespace and `/out` has no quota. See `docs/release-notes.md`
  (Known limitations) and spec §16.
- Reports that consist only of scanner output with no demonstrated impact.
- Content a user deliberately commits to their own repository. Cadence is a
  source control system; the server's scanner and quarantine are mitigations,
  not a guarantee.

## Disclosure

Reports are triaged in the order received; there is no formal response SLA and
no bug bounty. Please allow a reasonable window to ship a fix before publishing
details, and coordinate the disclosure date through the advisory. Once a fix is
released, the advisory records the affected versions, the fix, and any
mitigation.
