# Troubleshooting

Start with `docker compose ps` and
`docker compose logs migrate bootstrap cadence`. Variables are described in
[`.env.example`](.env.example).

## `/health` returns 502

**Symptom:** the proxy answers, the app page does not.
**Cause:** the proxy cannot reach the app, which publishes on `CAD_HTTP_BIND`
(`127.0.0.1` by default); only the bundled Caddy shares the stack network.
**Fix:** attach the proxy to the `cadence-prod` network, or use
`CAD_HTTP_BIND=0.0.0.0` and firewall the port. Check the app first:
`curl -fsS http://127.0.0.1:4000/health` prints `{"status":"ok"}` on the host.
If it does not, the logs are the answer, not the proxy.

## Passkeys fail on TrueNAS

**Symptom:** the browser reports an origin or RP ID mismatch.
**Cause:** the RP ID and origin must match the address bar. Reaching the stack as
`https://nas.local` while `CAD_PUBLIC_URL` says `https://cadence.example.com`, or
`internal` TLS on a name the client does not trust, fails every ceremony.
**Fix:** set `CAD_PUBLIC_URL` to the origin you browse, `CAD_WEBAUTHN_RP_ID` to
its hostname (no scheme, no port), and `CAD_WEBAUTHN_ORIGIN` to the same origin.
The RP ID is permanent: changing it invalidates every credential. A mismatch
fails the boot, so read `logs cadence` before the browser console.

## Daemon cannot reach the server

**Symptom:** the daemon reports timeouts and stays in offline mode.
**Cause:** the daemon dials `CAD_SERVER_URL` from the developer machine, a
different path from the browser's. A URL that resolves only inside the LAN, a
closed port, or a proxy with the app unpublished all look alike from there.
**Fix:** on the daemon machine, `curl -fsS https://<host>/health`. If that fails,
allow 443 (or `CAD_HTTP_PORT`) through the firewall and publish the app port
where the proxy can reach it. `CAD_PUBLIC_URL` is what the server prints in links
and what passkeys compare — it is not the daemon's connection target, and the
server derives its own host from it.

## Migrations pending, app never starts

**Symptom:** `cadence` stays stopped and `/health` never answers.
**Cause:** the app waits for `migrate` and `bootstrap` to exit 0. A failed
database connection, or an email set with a password under 12 characters, stops
it on purpose.
**Fix:** `docker compose logs migrate bootstrap`, then re-run them with
`docker compose run --rm migrate` and `docker compose run --rm bootstrap` (both
idempotent). If `CAD_DB_PASS` changed after first boot, the data directory was
initialized with the old password: point the stack back at the original
`postgres_data` volume rather than resetting it.

## See also

- [DEPLOY.md](DEPLOY.md) — layouts, backup/restore, upgrades.
- [README.md](README.md) — project overview and local demo.
