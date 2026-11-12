# Cadence — WebAuthn / Passkey (FIDO2) Plan

> **Status:** approved 2026-11-11; G1–G4 shipped (data/config/Wax verification,
> registration, passkey sign-in, management/recovery); G5 hardening and docs
> shipped except the physical browser/YubiKey matrix (§10.3), which stays on
> the release checklist.
> **Date:** 2026-11-11
> **Scope:** `apps/cadence_server` only. No daemon, shared-schema, or sync changes.
> **Approval:** `wax_ ~> 0.7` and the defaults below are approved. The §11/§12.6/§16
> rows in §12 are applied with the G1 meld (spec §11 and CONTRIBUTING.md).

## Approval record (2026-11-11)

- Dependency: `{:wax_, "~> 0.7"}` (Apache-2.0), plus the §11/§12.6/§16 rows.
- Stay on AshAuthentication 4.15.1; do not take the 5.0 RC.
- Replace `/sign-in` with a Cadence-owned page: OAuth + security key + demo
  password when compiled; keep the AAP callbacks.
- Store AAGUID and transports; never use them for authorization.
- Allow deleting the last key when an OAuth identity exists; warn clearly.
- Defer conditional UI and step-up-before-PAT to a later slice.
- Max 10 keys per user; labels 1–60 graphemes.
- No YubiKey-only (no-OAuth) deployment in v1; OAuth remains recovery.
- No app-rendered QR; use the browser-native cross-device QR only.

---

## 1. Recommendation (TL;DR)

1. **“QR code” means the browser’s native cross-device WebAuthn flow, not an
   app-rendered QR.** On a desktop with no local authenticator, Chrome/Edge/
   Safari offer “Use a phone” and draw the QR themselves. Cadence only supplies
   the challenge. We do **not** add a QR library, camera permission, or a
   phone-pairing token table. A YubiKey is USB/NFC and never needs a QR.
2. **Use `wax_` 0.7.0 for all FIDO2 cryptography, behind a small
   Cadence-owned layer.** Wax is the maintained Elixir relying-party library
   (challenge generation, attestation/assertion verification, COSE keys,
   `cbor`/`x509` parsing). It is the same library AshAuthentication 5.0 uses.
3. **Do not take the AshAuthentication 5.0 RC upgrade just for passkeys.**
   WebAuthn exists only in `ash_authentication` 5.0.0-rc (currently
   `5.0.0-rc.17`) plus `ash_authentication_phoenix` 3.0.0-rc; upgrading moves
   OAuth to Assent 0.3, changes generated action types, and hard-depends on
   Wax anyway. Cadence is on stable 4.15.1. Shape the credential table to
   match the AA5 strategy so a later migration is small.
4. **Add passkeys as an additional sign-in method for existing accounts**, not
   as a new-account source. Registration requires an authenticated session
   (OAuth or demo). GitHub/Google OAuth stays the recovery path. No passkey-only
   accounts in v1.
5. **Ceremonies run through ordinary controllers, not LiveView.** A WebAuthn
   sign-in must write the session cookie; that is natural in a controller and
   awkward in a LiveView (which needs a one-time-token handoff). Controller +
   HEEx + a small CSP-safe `passkeys.js` also fits Cadence’s no-bundler setup.

Target UX: **Account → Security → Add a security key** (name it, browser
prompt, PIN/touch), then **Sign in → Sign in with a security key or passkey**.
Phone passkeys work via the browser’s QR when the user chooses “Use a phone”.

---

## 2. Goals and non-goals

### Goals

- Register one or more WebAuthn credentials per user from an authenticated
  account-settings page, with a human label (e.g. “YubiKey 5C — desk”) and
  `created_at` / `last_used_at`.
- Sign in with a **YubiKey 5-series** over USB or NFC (CTAP2/FIDO2), including
  PIN/biometric **user verification**, and with platform/synced passkeys.
- Discoverable (resident) credentials, so sign-in needs no email. Conditional
  UI where the browser supports it.
- Browser-native cross-device QR for phone passkeys; no app-drawn QR.
- Credential management: list, rename, remove, replace; a second key for
  backup; a documented recovery path when every key is lost.
- Hard security defaults: RP ID/origin validation, one-shot challenges,
  strict sign-count handling, UV required, attestation `none`, rate limiting,
  no account enumeration, CSRF, session renewal.
- Coexist with the existing OAuth buttons, the compile-gated demo password,
  and daemon API keys. Disabled by default (`CAD_WEBAUTHN_ENABLED=false`).

### Non-goals

- Replacing OAuth or removing the demo password strategy.
- Passkey-based **account creation** / self-signup.
- Attestation trust (FIDO MDS), AAGUID allowlists, or enterprise attestation.
- Passkeys as a second factor / step-up flow (AA5’s `verify_enabled?` mode).
- App-rendered QR pairing, kiosk/TV login, or deep links into a phone app.
- YubiKey **PIV, OATH, OTP, OpenPGP, or FIDO U2F-only** applets. This is
  FIDO2/WebAuthn only; U2F-only keys (YubiKey 4/NEO) are unsupported and must
  fail with a clear message.
- Unattended/CLI login for daemons. Daemons keep API keys; passkeys only
  affect browser sessions.
- Recovery codes / email magic links. OAuth is the recovery method in v1.

---

## 3. What “QR code” means (read this first)

There are two different features that both involve a QR code. They are not the
same, and only one of them is WebAuthn.

### 3.1 Standard cross-device WebAuthn (“hybrid”, caBLE) — recommended

How it works:

1. Cadence calls `navigator.credentials.get({publicKey: …})` (or `.create`).
2. If the desktop has no usable local authenticator, the **browser/OS** offers
   “Use a phone” and renders a QR code in its own native prompt.
3. The user scans it with the phone camera; the phone’s passkey signs the
   challenge over BLE/hybrid transport; the desktop promise resolves.
4. Cadence receives the ordinary assertion and verifies it like any other.

What this means for Cadence:

- **No QR library, no camera access, no pairing table, no polling.** The app
  never renders or scans a QR. Adding `eqrcode` (which AAP 3 uses for TOTP
  setup) would not help WebAuthn.
- The RP ID and origin must be identical on both devices; the QR is bound to
  the desktop’s origin. Works with platform passkeys (iCloud Keychain, Google
  Password Manager, 1Password) and with a phone that has a registered passkey
  for Cadence.
- Browser/OS dependent: Chrome/Edge on desktop show the QR; Safari uses
  iCloud Keychain or “Use another device” depending on the OS. Enterprise
  policy can disable hybrid. Some flows need Bluetooth or a “computer & phone”
  pairing.
- **A YubiKey does not use this path.** It is a local USB/NFC authenticator:
  the browser shows “Insert your security key / Touch it / Enter PIN”.

### 3.2 App-rendered QR (phone-pairing handoff) — not recommended

This would be a different product feature: the desktop page draws a QR encoding
a one-time URL such as `https://cadence.example/pair/<token>`; the phone opens
it, authenticates with its passkey, marks the pairing approved; the desktop
page polls or receives a PubSub event and then creates its own session.

Why not in v1:

- The desktop is authenticated by **token possession**, not by a WebAuthn
  assertion for the desktop origin. That is a magic link with extra steps.
- New attack surface: pairing-token issuance, expiry, single use, device
  binding, CSRF, enumeration, and a second session handoff.
- It duplicates what the browser already does, with worse platform integration.
- It only makes sense for kiosks/TVs or browsers without WebAuthn, which is not
  the Cadence use case.

If a branded/app-rendered QR is ever explicitly required, it should be planned
as a separate “device pairing” feature with its own table and threat model —
not folded into this passkey work.

### 3.3 Copy we ship

Sign-in page hint, under the passkey button:

> **Using your phone?** Choose **Use a phone** in the browser prompt and scan
> the QR code with your camera. **Using a security key?** Plug it in and touch
> it when it blinks.

---

## 4. Current state and constraints

| Area | Current state |
|---|---|
| Framework | Phoenix 1.8, LiveView 1.2.13, Bandit, Plug 1.20 |
| Auth | `ash_authentication` 4.15.1, `ash_authentication_phoenix` 2.17.4, Ash 3.36, `ash_postgres` 2.15.2 |
| Human sign-in | GitHub/Google OAuth; `password :demo` compiled only when `CAD_DEMO_AUTH=true` (registration disabled) |
| Daemon auth | `AshAuthentication` API keys (`/sync/*`, bearer PAT) — untouched by this plan |
| Sessions | Signed cookie session (`_cadence_key`, `same_site: "Lax"`, `http_only: true`); **`secure` is not set** |
| Browser pipeline | `:browser` already has `fetch_session`, `fetch_flash`, `protect_from_forgery`, CSP, `load_from_session` |
| Assets | No Node/npm/esbuild. Prebuilt Phoenix/LiveView bundles + hand-written `app.js`, classic `<script>` tags |
| UI | Hand-written HEEx + CSS tokens; `app.html.heex` layout; `Presentation` helpers |
| Data | Server-only Ash domain `Cadence.Server.Accounts` (User/Token/UserIdentity/ApiKey); other server schemas are plain Ecto |
| Policies | No `Ash.Policy.Authorizer` anywhere; authorization is explicit in contexts/LiveViews |
| Tests | ExUnit, `Phoenix.ConnTest`, `Phoenix.LiveViewTest`, no Mox; 80% coverage floor; fake implementations for LLM/Docker |
| Gate | `mix format --check-formatted && mix compile --warnings-as-errors && mix test` |

Constraints that shape the design:

- **No bundler.** A passkey page must work with a plain `<script src>` and
  CSP `script-src 'self'`. No inline handlers (CSP blocks them), no npm import
  maps.
- **The session cookie must be written on the request that completes sign-in.**
  A controller does this naturally; a LiveView cannot set the cookie after
  mount without a handoff token.
- **RP ID is permanent.** Credentials are bound to `rp_id`; changing it later
  invalidates every registered key.
- **WebAuthn needs a secure context.** `http://localhost` and
  `http://127.0.0.1` are treated as secure; any other hostname needs HTTPS.
- **`user_verification: "required"` forces a PIN/biometric.** YubiKey 5-series
  supports a FIDO2 PIN (and Bio models support fingerprints). If no PIN is set,
  some browsers prompt to create one; others fail. U2F-only keys fail.
- **YubiKey discoverable-credential capacity is finite:** 25 on firmware
  5.0–5.6, 100 on 5.7+ (Bio: 25 on 5.5/5.6, 100 on 5.7+). Each Cadence account
  consumes one slot. Non-discoverable credentials do not consume slots, but
  they break usernameless sign-in.
- **Transports and AAGUID are metadata, not trust.** Transports are
  client-supplied; AAGUID identifies a model, not a device. Never use either
  for authorization.

---

## 5. Ecosystem findings (as of 2026-11-11)

### 5.1 AshAuthentication 4.15.1 — no WebAuthn support

The 4.15.1 API reference contains no `webauthn`/`passkey` module or strategy.
`AshAuthentication.Strategy` is extensible, but implementing a strategy means
owning the full ceremony, routes, session handling, and generated actions.

### 5.2 AshAuthentication 5.0.0-rc.17 — official WebAuthn strategy (release candidate)

- Package: <https://hex.pm/packages/ash_authentication> (latest stable
  **4.15.1**, latest **5.0.0-rc.17**, published 2026-11-07).
- Docs:
  <https://hexdocs.pm/ash_authentication/5.0.0-rc.17/dsl-ashauthentication-strategy-webauthn.html>
- It provides `webauthn` with: registration/sign-in, discoverable credentials,
  `user_verification` (`required`/`preferred`/`discouraged`), `attestation`
  (`none`/`direct`), `resident_key`, credential add/list/rename/delete actions,
  and a short-lived-token sign-in phase.
- It depends on `wax_ ~> 0.7` (optional in AA, mandatory in AAP 3).
- Upgrade cost from 4.15.1: `assent ~> 0.3.2` (Cadence locks 0.2.13), new
  `nimble_totp`, OAuth2/OIDC DSL changes (identity resource is required —
  Cadence already passes one), Google moves to OIDC, token `revoked?` becomes
  a generic action, and several CVE fixes. See the 5.0 upgrade guide:
  <https://hexdocs.pm/ash_authentication/5.0.0-rc.17/upgrading.html>
- Gaps against this plan: registration does not send `excludeCredentials`;
  `add_credential` stores only credential id/public key/sign count/label (no
  AAGUID/transports); sign-count handling is best-effort after verification, so
  clone detection is log-only.

### 5.3 ash_authentication_phoenix 3.0.0-rc.11 — official components (RC)

- Package: <https://hex.pm/packages/ash_authentication_phoenix> (stable
  **2.17.4**, latest **3.0.0-rc.11**).
- Provides `Components.WebAuthn` (sign-in/registration forms),
  `Components.WebAuthn.ManageCredentials`, `WebAuthnSetupLive`,
  `WebAuthnHelpers`, and `priv/static/webauthn_hooks.js`.
- `wax_ ~> 0.7` is a **non-optional** dependency at this version, so every
  install compiles the WebAuthn stack.
- The hooks are ES modules; the docs assume a bundler/import map. Cadence has
  neither, so `app.js` would have to become a module and import the hook file.
- Conditional UI is supported; the QR is still browser-native.

### 5.4 wax_ 0.7.0 — the relying-party crypto (stable)

- Package: <https://hex.pm/packages/wax_> (0.7.0, published 2025-05-18;
  612k downloads).
- Docs: <https://hexdocs.pm/wax_/0.7.0/Wax.html>
- Implements registration/authentication challenges, attestation and assertion
  verification, origin/RP checks, COSE keys, and passes the FIDO conformance
  suite (170 tests) per its README. Explicitly warns that it has not been
  independently security-reviewed.
- Dependencies: `cbor ~> 1.0`, `x509 ~> 0.8`, `asn1_compiler ~> 0.1`, `jason`.
- OTP 25+; no Phoenix/Ash coupling. This is the same library AA5 adopts.
- It does **not** do sign-count clone detection; it returns
  `authenticator_data.sign_count` and the application must enforce a rule.

### 5.5 webauthn_components 0.11.3 — LiveView components on Wax

- Package: <https://hex.pm/packages/webauthn_components> (0.11.3, published
  2026-10-17; 8.5k downloads).
- Provides `RegistrationComponent`, `AuthenticationComponent`,
  `ClientCapabilitiesComponent`, conditional mediation, `excludeCredentials`,
  and a plain `priv/static/webauthn_hooks.js` (no bundler needed).
- Host owns persistence and session. Challenge is held in the LiveView process
  (good one-shot semantics), but sign-in then needs a one-time-token handoff to
  a controller to set the cookie, and the component owns error/label copy.
- No Ash coupling; Elixir `~> 1.18`, Phoenix LiveView `~> 1.2`.

### 5.6 Other packages (not recommended)

| Package | Latest | Verdict |
|---|---|---|
| `webauthn` | 0.0.9 (2024-06) | Stale, tiny adoption |
| `web_authn_lite` | 0.6.0 (2024-05) | Stale; no passkey/discoverable focus |
| `glasskey` / `glasslock` | 1.0.0-rc1 (2026-08) | Gleam, RC, ~200/700 downloads; interesting but not proven |
| `ex_webauthn` | 0.1.0 (2026-04) | Rust NIF (`webauthn-rs`); adds a Rust toolchain to the release build |
| `exswan` | 0.1.0 (2026-08) | Brand new, tiny adoption |
| `eqrcode` | `~> 0.1` | TOTP QR only; irrelevant to WebAuthn |

**Verdict:** there is no stable, Ash-native WebAuthn option on Cadence’s
current versions. The maintained choice is Wax (directly or via AA5 RC). No
option justifies hand-writing COSE/CBOR/attestation parsing.

---

## 6. Option comparison

| Option | What it is | Fit | Cost | Risk |
|---|---|---|---|---|
| **A. AA 5.0 RC + AAP 3 RC** | Official strategy + components | Good Ash fit; passkey form appears on `sign_in_route`; ManageCredentials exists | Auth upgrade (Assent 0.3, OAuth DSL, action types) + schema + UI overrides | RC auth dependency in a 1.0 product; still needs custom work for AAGUID/transports/excludeCredentials/strict counters |
| **B. `wax_` + Cadence layer (recommended)** | Wax for crypto; own Ash resource, controllers, JS, UI | Exact control over YubiKey UX, labels, counters, error copy, schema | ~8–9 dev days | We own ~400–600 LOC of glue; crypto stays in Wax |
| **C. `webauthn_components` + AA 4.15** | LiveView components on Wax | Less ceremony JS; conditional UI; no auth upgrade | ~1 extra day for session handoff; less control | 0.11.x package; component owns copy/labels; sign-in handoff token |
| **D. Port AA5 strategy to AA4** | Vendor the RC strategy | Highest Ash fit | High | Maintaining a fork of auth code; internal API drift |
| **E. Hand-rolled FIDO2 / Rust NIF** | Own parser / `ex_webauthn` | — | Very high | Crypto and release-toolchain risk. Reject. |

**Decision: Option B.** It is the smallest change to the auth core, gives the
YubiKey/“SaaS-like” UX the user asked for, and keeps the credential schema
compatible with a future AA5 adoption. Option C is the fallback if the team
would rather not own the ceremony JS; Option A is the path when AshAuthentication
5.0 becomes stable.

---

## 7. Recommended architecture (Option B)

### 7.1 Components

```
apps/cadence_server/lib/cadence/server/
├── accounts/
│   ├── user.ex                         (+ has_many :webauthn_credentials)
│   ├── webauthn_credential.ex          (new Ash resource)
│   └── cose_key.ex                     (new Ash type: CBOR <-> Wax.CoseKey map)
├── passkeys.ex                         (new context: challenges, verify, CRUD)
└── passkey_rate_limit.ex               (new Hammer ETS limiter)

apps/cadence_server/lib/cadence/server_web/
├── controllers/
│   ├── sign_in_controller.ex           (new passkey-first sign-in page)
│   ├── passkey_session_controller.ex   (POST assertion -> session)
│   ├── account_security_controller.ex  (list / rename / delete)
│   └── passkey_registration_controller.ex (new key: challenge + POST)
├── plugs/
│   └── passkey_rate_limit.ex           (new plug)
└── templates/…                         (HEEx pages)

apps/cadence_server/priv/static/js/passkeys.js   (new, classic script)
apps/cadence_server/priv/repo/migrations/…       (new migration)
```

No change to `cadence_shared`, `cadence_daemon`, `GitStore`, or sync code.

### 7.2 Data model

New table `webauthn_credentials`, one row per credential (multiple per user):

```elixir
create table(:webauthn_credentials, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

  # Raw bytes. Base64url only at the HTTP/JS boundary.
  add :credential_id, :binary, null: false
  # CBOR-encoded COSE public key (Wax.CoseKey map at runtime).
  add :public_key, :binary, null: false

  add :sign_count, :bigint, null: false, default: 0
  add :aaguid, :binary              # 16 bytes; model id, diagnostics only
  add :transports, {:array, :string}, null: false, default: []
  add :attestation_type, :string    # "none" in v1
  add :label, :string, null: false, default: "Security key"
  add :last_used_at, :utc_datetime_usec
  timestamps()
end

create unique_index(:webauthn_credentials, [:credential_id])
create index(:webauthn_credentials, [:user_id])
```

Ash resource `Cadence.Server.Accounts.WebAuthnCredential`:

- `belongs_to :user, Cadence.Server.Accounts.User, allow_nil?: false`
- `identity :unique_credential_id, [:credential_id]`
- `public? false` for `credential_id`, `public_key`, `sign_count`, `aaguid`,
  `attestation_type` (never serialized); `public? true` for `label`,
  `transports`, `last_used_at`, timestamps.
- `CoseKey` type: `cast_stored/1` = `CBOR.decode/1` with a 256 KiB cap;
  `dump_to_native/1` = `CBOR.encode/1` (same approach as
  `AshAuthentication.Strategy.WebAuthn.CoseKey`, MIT).
- Validations: `credential_id` 1..1023 bytes; public key decodes to a map;
  label 1..60 graphemes, no control/bidi characters; `transports` a subset of
  `usb | nfc | ble | hybrid | internal | smart-card`; `sign_count >= 0`.
- Actions: `:create`, `:rename` (label), `:record_use` (sign_count +
  last_used_at), `:destroy`. No policy authorizer (repo convention); the
  context/controller checks `user_id`.
- Add `has_many :webauthn_credentials` to `User`.

AAGUID and transports are stored from day one because they are cheap and make
support/diagnostics and the device list useful. They are **advisory** and are
never used for authorization.

### 7.3 Challenge storage and replay protection

- Generate the challenge with Wax; store a serializable map in the **signed
  cookie session** under `"webauthn_challenge"`:
  `%{"bytes" => Base.encode64(bytes), "type" => "attestation"|"authentication",
  "origin" => …, "rp_id" => …, "issued_at" => unix_seconds,
  "user_id" => user_id (registration only)}`.
- **Delete the session key before verification**, on every POST (success or
  failure). One ceremony per challenge.
- Bind registration challenges to the authenticated `user_id`; a challenge
  minted for user A cannot create a credential for user B.
- Enforce a short lifetime server-side: `now - issued_at <= 120 s` (Wax also
  checks `timeout`; Wax’s option is seconds, the browser option is
  milliseconds — keep both at 120 s / 120000 ms).
- Why the cookie, not ETS/DB: it is multi-node safe, survives LiveView/process
  restarts, and the challenge is public randomness. A replay of an old signed
  cookie is bounded by the 120 s window and is blocked by the strict sign-count
  rule on the second use (§8). If a deployment ever needs server-side one-shot
  guarantees across captured cookies, add a `webauthn_challenges` table keyed
  by a hash with a consumed flag — deferred.

### 7.4 RP ID / origin configuration

- `rp_id` is a **hostname only**: no scheme, no port, no path
  (`localhost`, `cadence.example.com`). It must be a registrable suffix of the
  origin host.
- `origin` is the **full origin**: `https://cadence.example.com`,
  `https://localhost:4000`, `http://localhost:4000` (dev only).
- **In production, always set `CAD_WEBAUTHN_ORIGIN` explicitly.** A
  TLS-terminating proxy makes `conn.scheme`/`conn.host` internal; deriving the
  expected origin from the request would reject every ceremony. The explicit
  config also prevents Host-header games.
- In dev, derive the origin from `CAD_PUBLIC_URL` (already the source for
  endpoint URLs) or `http://localhost:<CAD_HTTP_PORT>`.
- **Boot validation** when `CAD_WEBAUTHN_ENABLED=true` (raise in
  `config/runtime.exs`, same pattern as the demo-auth guard):
  - `rp_id` matches `^[a-z0-9.-]+$`, contains no `:`/`/`, is not an IP literal
    (except `localhost`);
  - `origin` is a parseable URI with no path/query/fragment;
  - `origin.host` equals `rp_id` or ends with `"." <> rp_id`;
  - `origin.scheme == "https"` unless the host is `localhost`, `127.0.0.1`, or
    `[::1]`;
  - in `:prod`, `origin` is present and `https`.
- Document that **changing `rp_id` invalidates all credentials**. Pick the
  final production hostname before the first registration.

### 7.5 Registration flow (account settings)

1. `GET /account/security/keys/new` — authenticated only.
2. `Passkeys.registration_challenge(user)`:
   - `Wax.new_registration_challenge(origin: origin, rp_id: rp_id,
     user_verification: "required", attestation: "none", timeout: 120)`.
   - Store the challenge in the session (bound to `user.id`).
   - Build browser options: `rp: {id, name}`, `user: {id: handle, name: email,
     displayName: name}`, `pubKeyCredParams: [ES256(-7), RS256(-257)]`,
     `authenticatorSelection: {residentKey: "required",
     requireResidentKey: true, userVerification: "required"}`,
     `attestation: "none"`, `excludeCredentials: [existing credential ids]`.
   - `user.id` must be opaque and stable: use the first 32 bytes of
     `HMAC-SHA256(user.id, token_signing_secret)` (no PII, no extra column).
3. Page renders the options as `data-*` attributes (not inline JSON, to stay
   CSP-friendly) and a hidden form with CSRF.
4. `passkeys.js` calls `navigator.credentials.create({publicKey})`. The browser
   shows its native prompt: “Insert your security key”, “Touch it”, “Enter PIN”.
5. `POST /account/security/keys`:
   - pop the session challenge; reject if missing/expired/mismatched user;
   - `Wax.register(attestation_object, client_data_json, challenge)` →
     `{auth_data, _}`; require `fmt == "none"` and `UV == true`;
   - insert `WebAuthnCredential` with `credential_id`, `public_key`,
     `sign_count`, `aaguid`, `transports` (from the client, validated),
     `attestation_type`, label (default “Security key”, user-editable);
   - unique violation → “This security key is already registered on your
     account.”; per-user cap → friendly error;
   - redirect to `/account/security` with a flash.
6. YubiKey specifics: USB or NFC; PIN/biometric required; one resident slot per
   account (25/100 depending on firmware). A full key returns
   `ConstraintError` — copy: “Your security key has no free passkey slots.
   Remove an old passkey with Yubico Authenticator or use another key.” A
   U2F-only key returns `NotSupportedError` — copy: “This key doesn’t support
   FIDO2 user verification. Use a FIDO2 security key or a passkey.”

### 7.6 Sign-in flow

1. `GET /sign-in` renders:
   - **Primary:** “Sign in with a security key or passkey” button. The page
     already holds an authentication challenge (generated in the GET and
     stored in the session; `allowCredentials: []` for discoverable
     credentials).
   - Hint copy for phones (“Use a phone” → browser QR) and keys (“plug in,
     touch, PIN”).
   - OAuth buttons (`Continue with GitHub` / `Continue with Google`) linking to
     the existing `/auth/user/...` request phases.
   - Demo password form only when the demo strategy is compiled in.
2. `passkeys.js` calls `navigator.credentials.get({publicKey, mediation})`
   where `mediation` is `"conditional"` only if a username input with
   `autocomplete="username webauthn"` is present (hardening slice), otherwise
   `"optional"`.
3. On success, fill the hidden form (`raw_id`, `authenticator_data`,
   `signature`, `client_data_json`, `user_handle`) and submit to
   `POST /sign-in/passkey`.
4. `POST /sign-in/passkey`:
   - pop the challenge; reject if missing/expired;
   - find the credential by raw id; if unknown, return the generic failure
     (no account enumeration);
   - `Wax.authenticate(raw_id, auth_data, signature, client_data_json,
     challenge, [{raw_id, cose_key}])`;
   - require the UV flag; enforce the sign-count rule (§8);
   - `record_use/2` with a compare-and-swap on the old sign count;
   - `configure_session(renew: true)` then `store_in_session(user)`;
   - redirect to `/` (or a safe `return_to`).
5. Failures show one generic message (“Sign-in failed. Try again.”) plus a
   specific hint only for browser-side causes (cancelled/timeout, RP mismatch,
   UV missing) — never “no such account”.
6. If `CAD_WEBAUTHN_ENABLED=false`, the button is not rendered and both
   passkey POST endpoints return 404.

Coexistence with `sign_in_route`: v1 replaces the user-facing `/sign-in` route
with `SignInController` (and keeps `sign_out_route`, `auth_routes`, and
`ash_authentication_live_session` for project pages). The AAP sign-in page is
not needed once we render the OAuth links ourselves. A smaller alternative
(keep AAP’s page and link to `/sign-in/passkey`) is noted in §11.

### 7.7 Credential management and recovery

`/account/security` (authenticated):

- Header: “Security keys and passkeys”, with a short explainer.
- List per credential: label (editable), type hint from transports
  (“Security key (USB/NFC)”, “Passkey (this device)”, “Passkey (synced)”), added
  date, last-used date, remove action.
- “Add a security key” primary button; hint “Add a second key so you can still
  sign in if you lose this one.”
- Rename: `POST /account/security/keys/:id/rename` (trim, 1–60 graphemes,
  reject control/bidi).
- Remove: confirmation page or a CSP-safe `data-confirm` handler in
  `passkeys.js`; `POST /account/security/keys/:id/delete`.
- **Last-credential rule:** refuse removing the last credential unless at least
  one other sign-in method is configured (GitHub/Google OAuth env present, or
  the demo strategy). Copy: “Add another key first, or keep signing in with
  GitHub/Google.” If the deployment has no other method, the last key is
  undeletable (recovery would be operator-only).
- Recovery: sign in with OAuth → remove the lost key → add a replacement.
  Document an operator runbook for “all methods lost” (list/revoke rows via a
  read-only mix task or SQL; never edit `public_key` by hand).
- Per-user cap `CAD_WEBAUTHN_MAX_CREDENTIALS` (default 10).
- Optional (deferred): a small `mix cadence.passkeys` task (`list`, `revoke`)
  for operators.

### 7.8 UI / route surface

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/sign-in` | anonymous | Passkey button + OAuth + demo form |
| POST | `/sign-in/passkey` | anonymous | Verify assertion, set session |
| GET | `/account/security` | signed-in | Credential list |
| GET | `/account/security/keys/new` | signed-in | Registration challenge + page |
| POST | `/account/security/keys` | signed-in | Verify attestation, create row |
| POST | `/account/security/keys/:id/rename` | signed-in | Rename |
| POST | `/account/security/keys/:id/delete` | signed-in | Remove |

- All routes live in the `:browser` pipeline (`fetch_session`,
  `protect_from_forgery`, CSP).
- Header nav: the signed-in email becomes a link to `/account/security`
  (plus “Sign out”).
- No LiveView is required; pages are controller + HEEx. This avoids
  disconnected-mount DB queries and stream rules entirely.
- When disabled: no nav link, no passkey section, 404 on passkey POSTs.

### 7.9 JavaScript and CSP

- New `priv/static/js/passkeys.js`, loaded only on the passkey pages with
  `<script src="/assets/js/passkeys.js" defer>`.
- Plain DOM, no imports, no build step. Functions:
  - base64url ↔ `Uint8Array`;
  - `get()` / `create()` with the options from `data-*` attributes;
  - fill hidden form fields and submit;
  - map `DOMException.name` to copy (§7.10);
  - `data-confirm` handling for remove buttons;
  - optional conditional-UI wiring.
- CSP stays `script-src 'self'`; no inline handlers, no `unsafe-eval`, no
  external scripts. `form-action 'self'` already covers the POSTs.
- `app.js` is untouched (no LiveView hooks needed).

### 7.10 Error copy (browser + server)

| Cause | Message |
|---|---|
| `NotAllowedError` | “The request was cancelled or timed out. Try again, and touch your security key when it blinks.” |
| `InvalidStateError` | “This security key is already registered on your account.” |
| `SecurityError` | “The browser blocked the request because the site address doesn’t match. Contact your administrator.” |
| `NotSupportedError` | “This browser or key doesn’t support the required verification. Try a FIDO2 key or a passkey.” |
| `ConstraintError` | “Your security key can’t store another passkey (it may be full). Remove an old passkey from the key or use another key.” |
| `AbortError` | “The request was interrupted. Try again.” |
| Expired/missing challenge | “Your sign-in attempt expired. Try again.” |
| UV flag missing | “Your security key didn’t verify you. Set a PIN (or enroll a fingerprint) on the key and try again.” |
| Unknown credential | “Sign-in failed. Try again.” (generic; no enumeration) |
| Sign-count regression | “This security key’s signature counter went backwards. It may have been cloned. Use another sign-in method and contact your administrator.” |
| Server error | “Something went wrong. Try again or use GitHub/Google.” |

### 7.11 What “cleanly like a real SaaS product” means (concrete checklist)

- A real **account security page** with a device list, not a bare “register”
  endpoint.
- **Human labels** on every key (“YubiKey 5C — desk”, “MacBook Touch ID”),
  rename support, default labels by transports.
- **Added / last used** timestamps, visible and honest (last-used is
  best-effort).
- **Multiple keys**, with a prompt to add a backup.
- **Replacement** flow: add new → verify it works → remove old.
- **Recovery** copy and a working fallback (OAuth), plus an operator runbook.
- **Native prompts only**: never fake the browser’s security-key dialog; show
  pre-prompt guidance and post-error copy.
- **Error copy** for cancel, timeout, wrong origin, key full, U2F-only,
  already registered, and UV missing.
- **No dead ends**: every failure offers “try again” and “use GitHub/Google”.
- **Terminology**: say “security key” / “passkey”, not “YubiKey”, in generic
  copy (YubiKey is a trademark); link to Yubico help only in the hardware
  troubleshooting note.
- **Disabled by default** and invisible when disabled; demo builds still work.

---

## 8. Security checklist

| Requirement | Implementation |
|---|---|
| **User verification** | `user_verification: "required"` for registration and authentication; server rejects assertions without the UV flag. Forces YubiKey PIN/fingerprint; fails clearly for keys without UV. |
| **User presence** | Checked by Wax (UP flag). |
| **RP ID / origin** | Wax validates `rpIdHash` and `clientData.origin` against the challenge; explicit `CAD_WEBAUTHN_RP_ID`/`CAD_WEBAUTHN_ORIGIN`; boot-time validation; HTTPS unless localhost. |
| **Challenge lifecycle** | Random 32-byte challenge; stored in the signed session; bound to user (registration) and type; deleted before verification; 120 s lifetime; one ceremony per challenge. |
| **Replay protection** | One-shot challenge + strict sign-count rule + short expiry. |
| **Clone detection** | If stored `sign_count > 0` and new `sign_count > 0` and `new <= stored` → refuse, log a security event, keep the credential. If either side is 0, skip (some synced passkeys always report 0) and store `max(stored, new)`. Update with a compare-and-swap on the old count; a CAS miss is treated as suspicious and refused. |
| **Attestation** | `none`; accept `fmt == "none"` only; no MDS, no trust root, no AAGUID allowlist. AAGUID stored for diagnostics only. |
| **Credential storage** | `credential_id` raw bytes, unique index; COSE public key CBOR, size-capped; never serialized to HTML/JSON; no signing secrets. |
| **Duplicate keys** | `excludeCredentials` on registration + unique index; browser surfaces `InvalidStateError`. |
| **Account enumeration** | Discoverable sign-in with no email; one generic failure; registration only for authenticated users; no “unknown user” message. |
| **Rate limiting** | Hammer ETS, per IP (`CAD_WEBAUTHN_RATE_LIMIT`, default 10/min), plus a stricter per-credential bucket when known; `429` + `Retry-After`. Challenge GETs are also capped. |
| **CSRF** | Existing `protect_from_forgery`; all passkey POSTs are same-origin forms with `_csrf_token`. |
| **Session binding** | `configure_session(renew: true)` before `store_in_session/2`; session cookie `secure` in prod (prerequisite fix); `same_site: "Lax"`. |
| **Authorization** | Every controller action checks `conn.assigns.current_user`; every credential mutation scopes by `user_id` (no client-supplied user id); no `String.to_atom/1` on input. |
| **Input handling** | Base64url decode with size caps; label/transports validated; no `raw/1` of client data; log shapes only, never assertion bytes. |
| **Daemon API keys** | Unchanged; passkey sessions use the same AA session/token, so `/auth/tokens/new` still works. Optional later: require a passkey assertion in the last N minutes before minting a PAT (step-up). |
| **Lockout** | OAuth always remains; last-key deletion guarded; operator runbook. |
| **Observability** | Info log on add/remove (user id, credential id prefix, label); warning on counter regression/UV failure; no credential material in logs. |

---

## 9. Configuration (proposed `CAD_WEBAUTHN_*`)

All values are read in `config/runtime.exs` and stored in the application env;
nothing is hardcoded (spec §12.6).

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `CAD_WEBAUTHN_ENABLED` | no | `false` | Enable passkey/security-key sign-in and the account security page |
| `CAD_WEBAUTHN_RP_ID` | yes when enabled | `localhost` | Relying Party ID, hostname only; changing it invalidates every credential |
| `CAD_WEBAUTHN_RP_NAME` | no | `Cadence` | Name shown in the browser prompt |
| `CAD_WEBAUTHN_ORIGIN` | yes in prod when enabled | request/public URL in dev | Exact expected origin (`https://host[:port]`); required behind a TLS proxy |
| `CAD_WEBAUTHN_USER_VERIFICATION` | no | `required` | `required` \| `preferred` \| `discouraged` |
| `CAD_WEBAUTHN_TIMEOUT_MS` | no | `120000` | Browser ceremony timeout; server challenge lifetime is capped to the same window |
| `CAD_WEBAUTHN_MAX_CREDENTIALS` | no | `10` | Max credentials per user |
| `CAD_WEBAUTHN_RATE_LIMIT` | no | `10` | Ceremony POSTs per IP per window (`<= 0` disables) |
| `CAD_WEBAUTHN_RATE_SCALE` | no | `60000` | Rate window in milliseconds |

Attestation is fixed at `none` and resident keys at `required`; they are not
env-tunable in v1 (fewer ways to weaken the deployment).

**HTTPS/localhost:** `http://localhost`, `http://127.0.0.1`, and
`http://[::1]` are secure contexts. Anything else (including a LAN hostname or
`http://cadence.local`) needs HTTPS, or the browser refuses with
`SecurityError` before the request reaches Cadence.

---

## 10. Test plan

### 10.1 Unit

- `CoseKey` type: round-trip CBOR, size cap, invalid input.
- Credential changeset: required fields, label length/controls, transports
  allowlist, `sign_count >= 0`, credential-id length.
- `Passkeys` config: rp_id/origin parsing and the boot-validation rules
  (hostname only, suffix match, https/localhost, missing origin in prod).
- Sign-count rule: 0/0, 0/N, N/0, N/N+1, N/N, N/N-1.
- Last-credential rule: allowed with OAuth configured, refused without.

### 10.2 Integration with a fake authenticator

Write a small software authenticator fixture (Elixir, `:crypto`, no new dep):

- Generate a P-256 key; build `authData` = `SHA256(rp_id) || flags || signCount
  || AAGUID || credIdLen || credId || CBOR(COSE key)`;
- `attestationObject` = CBOR `%{"fmt" => "none", "attStmt" => %{},
  "authData" => authData}`;
- `clientDataJSON` with type/challenge/origin; assertion signature over
  `authData || SHA256(clientDataJSON)`.

Cases:

- Registration happy path creates one row with the expected fields.
- Sign-in happy path sets `current_user` and updates `last_used_at`/counter.
- Replay the same assertion → refused (challenge gone).
- Wrong challenge, wrong origin, wrong rp_id, tampered signature → refused.
- UV flag absent → refused.
- Duplicate credential id → refused, one row.
- Sign-count regression → refused + logged; 0 handling.
- Rename/delete; delete last credential (with and without OAuth); per-user cap.
- Disabled flag: routes 404, button absent.
- Rate limit: 11th attempt gets `429` + `Retry-After`.
- CSRF: POST without token is rejected.
- Session: `renew: true` produces a new session id (assert the cookie changes).

### 10.3 Browser-level

- WebAuthn needs a secure context; `localhost` qualifies. `Phoenix.ConnTest`
  and `LiveViewTest` cannot drive `navigator.credentials`, so the ceremony is
  covered by the fixture tests above.
- Optional: a Playwright/CDP script using `WebAuthn.addVirtualAuthenticator`
  for one end-to-end smoke (not in the CI gate).
- Manual matrix (release checklist):
  - YubiKey 5 NFC: Chrome Linux USB; Chrome Windows USB; Safari macOS USB;
    Android Chrome NFC; iPhone Safari NFC.
  - Registration with no PIN (browser prompts to create one) and with a PIN.
  - Sign-in with PIN, fingerprint (Bio), wrong PIN retries, key removed
    mid-prompt, key full (`ConstraintError`), U2F-only key (`NotSupportedError`).
  - Platform passkey: macOS Touch ID, Windows Hello, Android.
  - Cross-device: desktop Chrome → “Use a phone” → Android/iPhone QR → sign in.
  - Cancel/timeout, wrong RP (change rp_id in a scratch env), proxy origin
    mismatch, disabled deployment.
- Keep the manual evidence (browser/OS/key firmware) in the release review when
  the slice closes.

---

## 11. Phased slices and effort

Assumes one engineer familiar with the codebase; days are focused dev days.

| Slice | Deliverable | Depends on | Est. |
|---|---|---|---|
| **G0** | This document | — | done |
| **G1 — data + config + Wax spike (shipped)** | `wax_` dependency; `CoseKey` type; `WebAuthnCredential` resource + migration + snapshots; `Passkeys` challenge/verify skeleton; runtime config + boot validation; unit tests. Prove registration/sign-in against a localhost fake authenticator. | §11 approval | 1.5–2 d |
| **G2 — registration (shipped)** | `/account/security` + `/account/security/keys/new`; challenge in session; `create()`; `passkeys.js`; labels, cap, duplicate handling; nav link. | G1 | 2 d |
| **G3 — sign-in (shipped)** | Cadence-owned `/sign-in` (AAP components + passkey CTA); discoverable `get()`; `POST /auth/passkeys/sign-in`; session renewal; generic errors; QR/security-key copy. | G1 | 1.5 d |
| **G4 — management + recovery (shipped)** | Rename/remove, last-key rule, device list, last-used metadata, recovery copy, operator runbook (`docs/passkeys.md`), optional mix task. | G2 | 1.5 d |
| **G5 — hardening + docs (shipped; hardware matrix pending)** | Strict sign-count/CAS, rate limiter, error-copy table, origin/proxy tests, fake-authenticator matrix, manual browser matrix, spec §7.4/§11/§12.6/§12.9/§16 updates, `docs/release-notes.md`, `docs/demo.md`. The production session-cookie `secure` flag and demo-stack enablement shipped; the physical browser/key matrix remains a release-checklist item. | G2–G4 | 2 d |
| **G6 (optional)** | Conditional UI (username input + `mediation: "conditional"`), step-up before PAT minting, `mix cadence.passkeys` task. | G5 | 1–1.5 d |

Total: **~8–9 focused dev days** for G1–G5. Option C adds ~1 day; Option A
(AA5 RC upgrade) adds a 1–2 day spike plus the auth upgrade work and still
needs the same schema/UI/hardening.

---

## 12. Dependencies and spec deltas (approved — applied with G1)

### 12.1 Dependency to add

```elixir
# apps/cadence_server/mix.exs
{:wax_, "~> 0.7"}
```

Transitive (no separate §11 rows needed, like `yamerl` under `yaml_elixir`):
`cbor ~> 1.0`, `x509 ~> 0.8`, `asn1_compiler ~> 0.1`, `jason` (already
present).

**Not proposed:** `webauthn_components`, `eqrcode`, any AshAuthentication 5 /
AAP 3 upgrade, any JS package, any Rust NIF.

### 12.2 Exact spec §11 rows to add/change

Add after the Auth row:

```markdown
| Passkey / WebAuthn (FIDO2) | `wax_` `~> 0.7` (declared in `cadence_server`; server-side challenge generation, attestation/assertion verification, and COSE keys. Transitive `cbor`, `x509`, `asn1_compiler`. The browser performs the ceremony and draws the cross-device QR; the app renders none) |
```

Change the Auth row to:

```markdown
| Auth | `AshAuthentication` + `Ash` (GitHub/Google OAuth; daemon PATs use the API-key strategy; browser passkeys use a Cadence-owned WebAuthn layer on `wax_`, §7.4) |
```

### 12.3 Exact spec §12.6 rows to add

The nine `CAD_WEBAUTHN_*` rows in §9, inserted with the other server vars.

### 12.4 Spec §16 entries to add (open decisions)

```markdown
- [ ] **Passkey QR:** resolved by this plan’s recommendation — use the browser’s
      native cross-device WebAuthn (hybrid) QR. A Cadence-rendered QR is a
      separate phone-pairing feature (token table, expiry, single use) and is
      not adopted unless a kiosk/TV use case appears.
- [ ] **WebAuthn implementation:** `wax_` 0.7 behind a Cadence-owned layer on
      AshAuthentication 4.15. Revisit `AshAuthentication.Strategy.WebAuthn`
      when 5.0.0 is stable; the credential table is shaped to match it.
- [ ] **Attestation policy:** `none` (no FIDO MDS, no AAGUID allowlist, no
      trust root). Enterprise attestation is deferred.
- [ ] **Passkey-only accounts and recovery:** registration requires an existing
      OAuth/demo account; OAuth is the recovery path. Recovery codes and
      email magic links are deferred.
- [ ] **User-verification policy:** `required` for both ceremonies. U2F-only
      keys are unsupported.
```

### 12.5 Other docs to update when approved

- Spec §7.4 (auth), §12.9 (security notes: session `secure`, RP ID, proxy
  origin), §13 (phase note).
- `docs/demo.md` (YubiKey + phone QR walkthrough), `docs/release-notes.md`
  (feature + known limitations), `.env.example` (new vars), `docs/README.md`
  index link.
- `CONTRIBUTING.md` only if the contributor workflow changes — not needed.

---

## 13. Risks and blockers

| Risk | Impact | Mitigation |
|---|---|---|
| Wax is a small, single-maintainer library with an explicit “not independently reviewed” note | Crypto trust | It is the only maintained Elixir RP library and the one AA5 uses; pin `~> 0.7`, keep the 170-test conformance claim in mind, run our fixture matrix, and review the diff on upgrades. Do not hand-roll parsing. |
| AA 4.15.1 has no WebAuthn strategy | Must own glue | Glue is ~400–600 LOC around Wax; the hard crypto stays in Wax. Shape the schema for AA5. |
| AA 5 / AAP 3 are release candidates | Unstable auth dependency | Not adopted. Revisit when 5.0.0 is stable. |
| RP ID is permanent | Changing it breaks every key | Decide the production hostname before first use; document loudly; boot validation. |
| Proxy/TLS origin mismatch | Every ceremony fails with `NotAllowedError` | Explicit `CAD_WEBAUTHN_ORIGIN` in prod; boot validation; docs for reverse proxies. |
| YubiKey PIN setup friction / key capacity | Failed registration | Clear pre-prompt and error copy; 25/100 slot note; suggest a second key. |
| Lost keys | Lockout | OAuth fallback, last-key guard, operator runbook. |
| No automated browser tests | Regressions in the ceremony JS | Manual release matrix + optional CDP virtual authenticator; server-side fixture tests cover verification. |
| Session cookie lacked `secure` in prod | Session theft over HTTP (pre-existing) | Fixed in G5: the endpoint sets `secure` for `MIX_ENV=prod` and keeps dev/test/localhost working; documented in §12.9 and `docs/passkeys.md`. |
| Rate limiter is ETS (per node) | Weak bound in a multi-node deploy | Acceptable for the current single-node deployment; document; swap Hammer backend if scaled. |
| Attestation `none` allows any software authenticator | Weaker device assurance | Intentional (matches Yubico’s guidance not to allowlist models); UV + possession still required. |
| Passkeys don’t protect a compromised session | XSS/CSRF remains the front door | CSP, CSRF, `renew: true`, authorization on every mutation; step-up before PAT minting deferred. |
| YubiKey trademark / support expectations | UX/legal | Say “security key”; link to Yubico help for PIN/slot issues; no model allowlist. |

---

## 14. Open questions for the user (resolved by the approval record above)

The recommended option was taken for each item unless the approval record says
otherwise.

1. **Approve `wax_ ~> 0.7` and the §11 row?** This is the only new dependency;
   nothing can be implemented without it (spec §11).
2. **Stay on AshAuthentication 4.15.1 (recommended) or take the 5.0.0-rc
   upgrade** to use the vendor WebAuthn strategy? If the latter, is an RC auth
   dependency acceptable for 1.0.x?
3. **Replace `/sign-in` with the passkey-first page**, or keep the AAP page and
   add a “Sign in with a security key” link? (Recommended: replace; the AAP
   page is generic and cannot show a first-class passkey option without an
   upgrade.)
4. **Is AAGUID/transports required in v1?** The plan stores both; confirm no
   privacy objection (AAGUID is a model id, not a device id).
5. **Last-key deletion:** allow it when OAuth is configured (recommended), or
   refuse unconditionally like AAP’s `ManageCredentials`?
6. **Conditional UI in v1 or G6?** It needs a username input; hardware keys are
   still found via the explicit button.
7. **Require a recent passkey assertion (step-up) before minting daemon API
   keys?** Recommended defer; API keys stay as they are.
8. **Max credentials per user** (default 10) and label policy — any objections?
9. **Is a no-OAuth, YubiKey-only deployment expected?** If yes, the recovery
   rules change (last key becomes undeletable and a recovery code or operator
   path is needed).
10. **Do you explicitly want an app-rendered QR for a kiosk/TV or a phone app?**
    If yes, that is a separate pairing feature, not this WebAuthn slice.

---

## Appendix A — References

- AshAuthentication 4.15.1: <https://hexdocs.pm/ash_authentication/4.15.1/>
- AshAuthentication 5.0.0-rc.17 WebAuthn DSL:
  <https://hexdocs.pm/ash_authentication/5.0.0-rc.17/dsl-ashauthentication-strategy-webauthn.html>
- AshAuthentication 5.0 upgrade guide:
  <https://hexdocs.pm/ash_authentication/5.0.0-rc.17/upgrading.html>
- ash_authentication_phoenix 3.0.0-rc.11 WebAuthn components:
  <https://hexdocs.pm/ash_authentication_phoenix/3.0.0-rc.11/AshAuthentication.Phoenix.Components.WebAuthn.html>
- Wax 0.7.0 API: <https://hexdocs.pm/wax_/0.7.0/Wax.html>
- webauthn_components 0.11.3: <https://hexdocs.pm/webauthn_components/>
- W3C WebAuthn Level 2: <https://www.w3.org/TR/webauthn-2/>
- Yubico WebAuthn developer guide (UV, resident keys, credential management):
  <https://developers.yubico.com/WebAuthn/WebAuthn_Developer_Guide/>
- YubiKey discoverable-credential capacity:
  <https://support.yubico.com/hc/en-us/articles/360013790319>
- YubiKey Technical Manual, FIDO specifics:
  <https://docs.yubico.com/hardware/yubikey/yk-tech-manual/yk5-apps-fido.html>

## Appendix B — Explicitly out of scope

- YubiKey PIV, OATH, OTP, OpenPGP, and FIDO U2F-only applets.
- Passkey self-registration / account creation.
- SSO/SCIM, team-level passkey policy, admin-forced key rotation.
- Storing or displaying attestation certificates, MDS metadata, or AAGUID
  allowlists.
- A Cadence-rendered QR, phone pairing, kiosk/TV login, or native mobile apps.
- Push notifications / email alerts on key changes (no mailer in the app).
- Recovery codes and magic-link sign-in.
