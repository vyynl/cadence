# Security keys and passkeys

Cadence supports WebAuthn (Web Authentication) / FIDO2 (Fast Identity Online 2)
**security keys** — a YubiKey 5-series or another FIDO2 key — and
platform or synced **passkeys** as a browser sign-in method for existing
accounts. It is off by default. OAuth remains the account-recovery path;
passkeys do not replace it and cannot create accounts.

This page is the operator and end-user runbook. For the design rationale, see
[`webauthn-plan.md`](webauthn-plan.md); for the configuration contract, see
[spec §7.4](spec.md#74-auth) and
[§12.6](spec.md#126-environment-variable-contract).

## At a glance

- **What you get:** a second browser sign-in method using a hardware key or a
  platform/synced passkey, with user verification on every ceremony.
- **What you need:** an existing OAuth (or demo) account, a permanent public
  hostname, and HTTPS outside `localhost`.
- **Default:** disabled. Enable it with `CAD_WEBAUTHN_ENABLED=true` and a valid
  RP ID and origin.
- **Recovery:** OAuth. There are no recovery codes and no passkey-only accounts.
- **Permanence:** the RP ID (relying party ID) is bound to every credential.
  Changing it invalidates every registered key.

## Prerequisites

- A Cadence server reachable over HTTPS, or `http://localhost` for development.
- An OAuth provider configured for human sign-in. Every account that may
  register a passkey needs a recovery path.
- A permanent public hostname chosen **before** the first key is registered.
- A FIDO2/CTAP2 authenticator for hardware testing: YubiKey 5-series over USB
  or NFC, a platform passkey (Touch ID, Windows Hello, Android), or a synced
  passkey (iCloud Keychain, Google Password Manager, 1Password).

## What is supported

| Supported | Not supported |
|---|---|
| FIDO2/CTAP2 (Client to Authenticator Protocol 2) keys over USB, near-field communication (NFC) (YubiKey 5-series), or Bluetooth Low Energy (BLE) (other FIDO2 keys) | FIDO U2F-only keys (YubiKey 4/NEO) — registration fails with `NotSupportedError` |
| Platform passkeys (Touch ID, Windows Hello, Android) and synced passkeys (iCloud Keychain, Google Password Manager, 1Password) | Passkey **account creation** or self-signup |
| Phone passkey through the browser's native **Use a phone** QR (hybrid/caBLE) | A Cadence-rendered QR, kiosk/TV login, or a phone-pairing flow |
| Several named credentials per account (default cap 10) | Attestation trust, FIDO MDS (Metadata Service), AAGUID allowlists, or enterprise attestation |
| Discoverable (resident) credentials, so sign-in needs no email | Recovery codes, email magic links, or passkey-only accounts |
| User verification with PIN or biometric, required on every ceremony | YubiKey PIV, OATH, OTP, OpenPGP, or U2F applets |
| Removing the last key while signed in (OAuth remains) | CLI or daemon login with a passkey; daemons keep API keys |

The browser performs the ceremony and draws the cross-device QR. Cadence only
mints the challenge and verifies the response server-side. AAGUID is the
authenticator model identifier reported during registration; it is displayed as
diagnostic metadata, never used for authorization.

## Configuration

All settings are `CAD_WEBAUTHN_*`, read in `config/runtime.exs`
([spec §12.6](spec.md#126-environment-variable-contract)). Disabled is
the default; when enabled, a bad RP ID or origin fails the boot instead of
failing every ceremony at runtime.

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `CAD_WEBAUTHN_ENABLED` | no | `false` | Enable the account security page, registration, and passkey sign-in |
| `CAD_WEBAUTHN_RP_ID` | when enabled | `localhost` | Relying Party ID: a hostname only, no scheme, port, or path. **Permanent** |
| `CAD_WEBAUTHN_RP_NAME` | no | `Cadence` | Name shown in the browser prompt |
| `CAD_WEBAUTHN_ORIGIN` | when enabled | `CAD_PUBLIC_URL` in dev; required in prod | Exact browser origin (`https://host[:port]`); required behind TLS termination |
| `CAD_WEBAUTHN_USER_VERIFICATION` | no | `required` | `required`, `preferred`, or `discouraged`. Keep `required` |
| `CAD_WEBAUTHN_TIMEOUT_MS` | no | `120000` | Browser ceremony timeout; the server challenge lifetime uses the same window |
| `CAD_WEBAUTHN_MAX_CREDENTIALS` | no | `10` | Maximum credentials per user |
| `CAD_WEBAUTHN_RATE_LIMIT` | no | `10` | Ceremony POSTs per client IP per window; `0` or negative disables |
| `CAD_WEBAUTHN_RATE_SCALE` | no | `60000` | Rate window in milliseconds |

Minimal production example:

```bash
CAD_WEBAUTHN_ENABLED=true
CAD_WEBAUTHN_RP_ID=cadence.example.com
CAD_WEBAUTHN_ORIGIN=https://cadence.example.com
CAD_WEBAUTHN_RP_NAME=Cadence
```

`RP_ID` must equal the origin host or be a registrable suffix of it. For example,
`RP_ID=cadence.example.com` accepts `https://cadence.example.com` and
`https://app.cadence.example.com`; it does not accept `https://example.com`.
`http://localhost`, `http://127.0.0.1`, and `http://[::1]` are secure contexts
and are allowed for local development and the demo; every other host needs
HTTPS, or the browser refuses before the request reaches Cadence.

### Reverse proxy and TLS

Cadence serves HTTP internally; TLS is the proxy's job. Behind a proxy the
request Cadence sees has an internal scheme and host, so **`CAD_WEBAUTHN_ORIGIN`
must be the exact public origin**, not the internal one:

```text
Browser origin:  https://cadence.example.com
CAD_WEBAUTHN_ORIGIN=https://cadence.example.com   # exact, no trailing slash
CAD_WEBAUTHN_RP_ID=cadence.example.com
```

Common failures:

- `CAD_WEBAUTHN_ORIGIN=http://cadence.example.com` behind an HTTPS proxy:
  every registration and sign-in fails with `SecurityError` or a server
  origin-mismatch message.
- The origin includes a path, query, or a port the browser does not use, or a
  trailing slash. Boot validation rejects a path or query; a wrong port or
  scheme gets past boot and then fails every ceremony.
- The proxy serves the app on a different hostname than `RP_ID`. Cookies and
  WebAuthn are both origin-scoped; fix the hostname, do not add a second origin.
- A plain-HTTP bare hostname (`http://cadence.local`) is not a secure context.
  Use HTTPS or `localhost`.

The rate limiter keys on the TCP peer address. Behind a proxy, every client
shares the proxy address unless the deployment rewrites the peer address
(`Plug.RewriteOn`); a shared 10/min bucket is usually fine for a small
deployment, but raise `CAD_WEBAUTHN_RATE_LIMIT` or forward client IPs if many
users sign in through one proxy.

### Session cookie

The signed session cookie (`_cadence_key`) is `http_only`, `same_site: "Lax"`,
and, for a `MIX_ENV=prod` build, `secure`. The flag is fixed at endpoint
compile time; dev/test and the local demo stay non-`secure` so
`http://localhost` works. A production release must be served over HTTPS — a
prod build served over plain HTTP will not retain sessions. Rotating
`CAD_SECRET_KEY_BASE` invalidates sessions and in-flight challenges.

### Disabled mode

With `CAD_WEBAUTHN_ENABLED=false` (the default):

- `/account/security*` and `/auth/passkeys/sign-in` return 404.
- The `/sign-in` page shows only OAuth (and the compile-gated demo password).
- Existing credential rows are kept but unusable until the feature is enabled
  again with the same RP ID.

Secrets are unaffected: no credential secret is stored server-side, so
disabling does not destroy keys.

## Register a YubiKey (USB or NFC)

1. Sign in with OAuth (or the demo password) at `/sign-in`.
2. Open **Account** in the header, or go to `/account/security`.
3. Choose **Add a security key or passkey**.
4. Give the key a name you will recognise later, for example
   `YubiKey 5C — desk`. Names are 1–60 characters and are only labels.
5. Choose **Add key**. The browser prompt appears:
   - **USB:** plug the key in and touch it when it blinks.
   - **NFC:** hold the key against the phone or reader and confirm.
   - If the key has no FIDO2 PIN, the browser asks you to create one. Choose a
     PIN you can remember; Cadence does not store it.
   - If the key has a fingerprint enrolled, verify with the fingerprint instead
     of typing the PIN.
6. The browser sends the attestation; Cadence verifies it and redirects to
   `/account/security`, where the key appears with its transport and added date.
   The first sign-in with it updates **last used**.

Cadence requests **user verification** (`required`), a **resident/discoverable**
credential, and attestation `none`. A key that cannot do user verification or
resident credentials is rejected with a clear message rather than silently
weakened.

The YubiKey stores the credential in its FIDO2 applet. It is independent of the
PIV, OATH, OTP, and OpenPGP applets and of any other account's credential;
resetting a PIV PIN does not touch it, but resetting the FIDO2 applet deletes
it.

### Add a second key

Do this before you need it. Register a second key the same way, name it
`YubiKey 5 NFC — backup`, and store it separately. The account page warns when
only one key is registered. Two keys also let you remove a lost or retired key
without losing access.

### Rename or remove a key

- `/account/security` lists each credential with its label, transport hint,
  added date, and last-used date.
- **Rename** changes only the label.
- **Remove** is a two-step confirmation (open **Remove**, then **Remove key**).
  It is scoped to your account; a guessed row ID cannot touch another user.
- Removing the **last** key is allowed because OAuth (or the demo password) can
  still sign you in. The page warns you first. If you have no OAuth identity and
  no demo password, do not remove the last key.

Duplicate registration of the same key on the same account is refused
(`excludeCredentials` plus a unique index); the browser typically reports
`InvalidStateError`. The same physical key may be registered by several
different Cadence accounts — each account gets its own resident credential.

## Phone passkeys and the native QR

Cadence does not render a QR code. On a desktop with no local authenticator, the
browser's own prompt offers **Use a phone** and draws the QR. Scan it with the
phone camera and approve on the phone; the desktop browser completes the
ceremony.

- Registration: choose **Add a security key or passkey** on the desktop, then
  **Use a phone** in the browser prompt.
- Sign-in: choose **Sign in with a security key or passkey**, then **Use a
  phone**.
- The ceremony is bound to the desktop's `CAD_WEBAUTHN_ORIGIN` and RP ID. The
  phone must have, or create, a passkey for the same RP ID; a passkey registered
  for a different site will not be offered.
- Hybrid/caBLE needs Bluetooth or local proximity and may be disabled by
  enterprise browser policy. iCloud Keychain, Google Password Manager, and
  1Password can also act as synced passkeys without a QR.

A YubiKey never needs a QR. A passkey created in a phone's platform keychain can
be used in the phone browser directly or cross-device through the browser.

## RP ID is permanent

`CAD_WEBAUTHN_RP_ID` is the WebAuthn scope. Every credential is bound to it.

- Changing it, including changing the production hostname, invalidates **every
  existing credential**. There is no migration; users must register again.
- Decide the production hostname before the first key is registered.
- Subdomains of the RP ID are acceptable origins, but the RP ID itself should be
  the stable registrable domain, not a throwaway host.
- Restoring an old database with credentials does not help if the RP ID
  changed; the signatures are bound to the RP ID.

Changing `CAD_WEBAUTHN_ORIGIN` to another origin **under the same RP ID** (for
example `https://app.cadence.example.com` to `https://cadence.example.com`)
does not invalidate credentials, but the browser only offers them on origins the
RP ID covers. Changing to a host outside the RP ID is effectively an RP change.
Keep both values stable, and avoid using a hostname you may lose.

## Recovery: lost key, lost phone, last key gone

OAuth is the recovery path in v1. There are no recovery codes and no email magic
links.

1. Sign in with GitHub or Google (or the demo password in the demo stack).
2. Open `/account/security`.
3. Remove the lost credential.
4. Add a replacement key or passkey.

If the **last** key is lost and OAuth is configured, the account is recoverable
through OAuth. If the account has no OAuth identity, there is no supported
self-service recovery: a deployment without OAuth is not a supported passkey
deployment (the demo password is the demo-only exception). An operator with
database access can delete the `webauthn_credentials` row, but that is a manual
break-glass action, not a supported workflow; treat it as incident response.

Lost-key hygiene:

- Remove the old credential as soon as you have OAuth access; it cannot be used
  without the physical key, but leaving it only confuses the device list.
- Register the replacement before travelling.
- If a key is stolen, removing it does not revoke a copied credential; no
  server-side secret exists to revoke. The sign counter and user verification
  are the clone-detection and assurance mechanisms. Rotate anything else the
  key protected.

## Security model

- **User verification is required** for registration and sign-in. The server
  rejects an assertion without the user-verification flag; a key must have a PIN
  or biometric.
- **User presence** is checked by the authenticator and Wax through the
  user-presence flag.
- **Attestation is `none`.** Cadence accepts any authenticator, including
  software and virtual authenticators. There is no FIDO Metadata Service, no
  AAGUID allowlist, no custom CA, and no enterprise attestation. Possession plus
  user verification is the assurance model; AAGUID and transports are
  display/diagnostic hints only.
- **Challenges** are random 32-byte values stored in the signed session, bound
  to the user (registration) and ceremony type, valid for the configured
  window, and deleted before verification — one ceremony per challenge.
- **Sign counters:** if both stored and received counters are non-zero, a
  non-advancing counter is refused and logged. Zero is accepted (many synced
  passkeys always report zero) and never lowers the stored maximum. The update
  is a compare-and-swap, so two concurrent assertions cannot both win.
- **No account enumeration:** discoverable sign-in needs no email, and every
  verification failure maps to the same generic message.
- **Rate limiting:** the two ceremony POSTs are limited per client IP
  (`CAD_WEBAUTHN_RATE_LIMIT` / `CAD_WEBAUTHN_RATE_SCALE`), returning `429` with
  `Retry-After`. The challenge GETs are not rate-limited; they are cheap and
  mint only a signed-session challenge. There is no separate per-credential
  bucket in v1.
- **CSRF:** both ceremony POSTs are same-origin forms or JSON with the CSRF
  token; the normal `protect_from_forgery` pipeline applies.
- **Session renewal:** a successful passkey sign-in renews the session before
  storing the AshAuthentication session, so a pre-authentication session cannot
  be reused.
- **Secrets:** the credential ID, COSE public key, AAGUID, sign count, and
  attestation type are never serialized to HTML or JSON and are never written to
  logs.
- **Step-up:** a passkey is not required before minting a daemon API key in v1;
  API keys keep their existing authorization. Conditional UI and autofill are
  deferred.

The usual web front door still applies: passkeys do not protect a compromised
session, XSS, or CSRF, so keep the CSP, CSRF protection, and HTTPS in place.

## Rate limits and multi-node notes

- Default: 10 ceremony POSTs per client IP per 60 seconds, fixed window,
  in-memory (Hammer ETS).
- A denial is `429` with `Retry-After` in seconds. A user who retries too fast
  should wait and try again; the challenge may also expire, in which case the
  page asks them to start over.
- The limiter is per server node. A multi-node deployment needs a shared Hammer
  backend or per-node limits sized accordingly.
- Challenges live in the signed session cookie, so any node with the same
  `CAD_SECRET_KEY_BASE` can verify them; sticky sessions are not required.

## Verify

- `/sign-in` shows **Sign in with a security key or passkey** only while the
  feature is enabled.
- `/account/security` loads for a signed-in user and lists registered keys.
- A test registration completes the browser prompt and appears in the list with
  a transport and added date.
- Signing out and choosing the passkey option returns you to the portfolio
  signed in.
- With `CAD_WEBAUTHN_ENABLED=false`, `/account/security` and
  `/auth/passkeys/sign-in` return 404.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Browser prompt never appears; console `SecurityError` | Origin is not a secure context (plain HTTP on a non-localhost host), or `CAD_WEBAUTHN_ORIGIN` and `RP_ID` do not match | Use HTTPS (or `localhost`), make the origin exact, and restart after fixing the environment |
| `NotAllowedError` immediately, or "request cancelled or timed out" | User cancelled, prompt timed out, no matching credential, or user verification failed | Retry; touch the key when it blinks; check the key's PIN or fingerprint; make sure the key is FIDO2 and registered for this RP |
| `NotAllowedError` on every attempt behind a proxy | `CAD_WEBAUTHN_ORIGIN` is the internal origin or the wrong scheme/port | Set the exact public `https://` origin and the matching RP ID |
| `InvalidStateError` | This credential is already registered on this account | Use the existing key; remove the old entry first if re-registering a reset key |
| `NotSupportedError` | U2F-only key, or a key/browser without the required user-verification or resident-key support | Use a FIDO2/CTAP2 key or a platform passkey |
| `ConstraintError` or "key may be full" | The authenticator has no resident-credential space | Remove an old passkey from the key with the vendor's tool, or use another key |
| Key blinks but nothing happens | NFC not aligned, USB cable/port issue, or the browser is waiting for touch | Re-seat the key, touch the gold contact, try another port |
| Wrong PIN | The FIDO2 PIN, not the OS/login PIN | Retry carefully; a YubiKey allows a limited number of attempts before the FIDO2 applet must be reset (which deletes its credentials) |
| 429 from the ceremony POST | Per-IP rate limit | Wait for `Retry-After`; raise the limit for shared proxies |
| Account page 404 or no passkey option | `CAD_WEBAUTHN_ENABLED=false`, or the boot rejected the configuration | Set the flag and a valid `RP_ID`/`ORIGIN`; check the boot log for the validation message |
| Sign-in succeeds but the next request is anonymous | Production release served over HTTP, so the `secure` session cookie is dropped | Terminate TLS at the proxy and use the public HTTPS origin |
| A key that used to work now fails | RP ID or origin changed | Restore the original values; otherwise every credential must be re-registered |

Server-side failures are generic by design: the sign-in page never says whether
an account or credential exists.

## Operational checklist

Before enabling in production:

- [ ] Pick the permanent public hostname and set `CAD_WEBAUTHN_RP_ID` to its
      registrable domain.
- [ ] Set `CAD_WEBAUTHN_ORIGIN` to the exact `https://` origin, with no
      trailing slash.
- [ ] Confirm the proxy terminates TLS and forwards to Cadence over HTTP.
- [ ] Keep `CAD_WEBAUTHN_USER_VERIFICATION=required`.
- [ ] Size `CAD_WEBAUTHN_RATE_LIMIT` for the proxy and client-IP topology.
- [ ] Boot once and confirm the boot log does not raise a WebAuthn validation
      error; then load `/account/security` as a test user.
- [ ] Register two keys for the owner account before announcing the feature.
- [ ] Keep OAuth configured for every human account; it is the recovery path.
- [ ] Add the manual browser and key matrix from
      [`webauthn-plan.md`](webauthn-plan.md#103-browser-level) to the release
      checklist for the hardware you support.

## Related docs

- [Production deployment](deploy.md#passkeys) — server variables and TLS.
- [Demo stack](demo.md) — try passkeys on `localhost` without hardware.
- [WebAuthn design note](webauthn-plan.md) — rationale, threat model, and the
  remaining hardware matrix.
- [Spec §7.4](spec.md#74-auth) — authentication contract.
- [Security policy](../SECURITY.md) — private vulnerability reporting.
