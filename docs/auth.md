# Accounts, TOTP, and sessions

Cadence uses operator-created local accounts with a password and mandatory
time-based one-time passwords (TOTP). OAuth (GitHub/Google) and passkeys are
optional secondary methods. There is no public registration and no
password-reset email.

The normative contract is [spec §7.4](spec.md#74-auth); this page is the
operator and end-user runbook.

## Create an account

From a source checkout:

```bash
mix cadence.user --email you@example.com --name "Your Name"
# Password comes from CAD_USER_PASSWORD, or it is prompted for (min 12 chars).
```

From a running release container:

```bash
bin/cadence eval 'Cadence.Server.Release.create_user("you@example.com", "Your Name", "a long password")'
```

The first sign-in at `/sign-in` asks for the password, then forces TOTP
enrollment with a QR code and manual secret. Confirm a code from the
authenticator app; Cadence shows **ten recovery codes once**. Store them
offline.

`mix cadence.user --reset-password --email …` replaces the password
(`Release.reset_password/2` in a release). `--reset-totp` removes the TOTP
secret and every recovery code so the next login re-enrolls
(`Release.reset_totp/1`). Password and TOTP state are otherwise never changed
implicitly.

## Sign in

- Password accounts: password → TOTP challenge (`/sign-in/totp`) → session. A
  recovery code works in place of the six-digit code and is consumed on use.
  A password-only account that has not enrolled is sent to
  `/sign-in/totp/setup` and cannot reach the app until enrollment is complete.
- The pending password hand-off expires after five minutes; sign in again.
- **Keep me signed in for 14 days** writes a signed remember-me cookie. The
  session token is rotated weekly and the database stores only its hash.
- OAuth accounts without TOTP go straight to a session; if they enroll TOTP,
  later OAuth sign-ins also ask for the code.
- Passkey sign-in does not ask for TOTP: the passkey already provides
  possession plus user verification.
- **Sign out** from the header (a CSRF-protected POST). It deletes the session
  row and disconnects open LiveViews. Password changes sign out every other
  session; **Account → Sign out of every session** signs out the current one
  too.

## Account settings

`/account` (header **Account**) shows:

- email and whether a local password is set;
- password set/change (at least 12 characters; other sessions are revoked);
- TOTP status, recovery-code count, setup, regenerate, and disable;
- links to `/account/security` (passkeys) and `/auth/tokens/new` (daemon token);
- **Sign out of every session**.

Credential changes require **sudo mode**: a sign-in within
`CAD_AUTH_SUDO_MINUTES` (default 20). If the session is older, Cadence sends
you through `/sign-in?sudo=1&return_to=…` and returns afterwards.

## Rate limits

- Login: 20 attempts per client IP per minute and 5 per IP + email per minute.
- TOTP/recovery: 10 attempts per user per five minutes.

All are configurable and a non-positive limit disables that bound; see
[spec §12.6](spec.md#126-environment-variable-contract).

## Demo accounts

The demo stack seeds `owner@demo.local`, `approver@demo.local`,
`viewer@demo.local`, and `outsider@demo.local`, all with password
`cadence-demo` and a fixed TOTP secret. Print the current code with:

```bash
docker compose exec server mix cadence.totp --email owner@demo.local
```

A code already used in the current 30-second step is deliberately rejected;
wait for the next one. See [Demo stack](demo.md).

## Recovery

- Lost authenticator: use an unused recovery code, then regenerate codes from
  `/account`. If every code is gone, an operator runs
  `mix cadence.user --reset-totp --email …`.
- Lost password: an operator runs `mix cadence.user --reset-password --email …`.
- Lost passkey: sign in with password + TOTP (or OAuth) and remove it from
  `/account/security`.
- Rotating `CAD_TOTP_KEY` (or `CAD_SECRET_KEY_BASE` when it is derived) makes
  stored TOTP secrets undecryptable; reset TOTP per account.

## Configuration

The short list:

| Variable | Default | Purpose |
|---|---|---|
| `CAD_AUTH_PASSWORD_MIN_LENGTH` | `12` | Local password floor (max 72 bytes) |
| `CAD_AUTH_TOTP_REQUIRED` | `true` | Force TOTP for local password accounts |
| `CAD_AUTH_TOTP_ISSUER` | `Cadence` | Issuer in the enrollment QR code |
| `CAD_TOTP_KEY` | derived | TOTP secret encryption key (32 raw bytes, base64, or passphrase) |
| `CAD_AUTH_SUDO_MINUTES` | `20` | Recent-authentication window |
| `CAD_SESSION_TTL_DAYS` | `14` | Session and remember-me lifetime |
| `CAD_SESSION_REISSUE_DAYS` | `7` | Token rotation age |

The full contract, including every rate-limit key, is
[spec §12.6](spec.md#126-environment-variable-contract).
