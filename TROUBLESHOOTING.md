# Troubleshooting

Start with `docker compose ps` and
`docker compose logs migrate bootstrap cadence`. Variables are described in
[`.env.example`](.env.example).

## `docker compose up -d` fails with `unauthorized`

**Symptom:** `Error response from daemon: error from registry: unauthorized`,
before any container starts.
**Cause:** the image lives in a private GHCR package and this machine has no
registry credentials, so `docker pull` cannot see it. `docker compose ps` shows
nothing because nothing was created. Package visibility is a **separate setting
from the repository's**: making the repository public does not change an
existing package, so a public repo can still serve a private image.
**Fix:** log in once with a token that has `read:packages`:

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin
```

Or make the package public: GitHub → Packages → `cadence` → Package settings →
Change visibility. Public is the right choice for a self-hosted product, because
it removes this step for every operator.

With no registry access at all, build from a checkout instead. The compose file
runs whatever `CAD_SERVER_IMAGE` names:

```bash
docker build -f docker/Dockerfile -t ghcr.io/vyynl/cadence:latest .
docker compose up -d
```

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

**Symptom:** the daemon logs `Req.TransportError{reason: :timeout}` (or
`econnrefused`) and stays in offline mode; commits pile up locally.
**Cause:** `CAD_SERVER_URL` must resolve *from the daemon's network namespace*,
and the stack publishes the app on loopback by default. A container daemon
cannot reach `http://localhost:4000` (that is the daemon container itself), and
`host.docker.internal` does not help either, because `CAD_HTTP_BIND` is
`127.0.0.1`. A LAN name, a closed port, and a proxy that does not publish the app
all look the same from there.
**Fix:** put the daemon on the server's network and dial the service name. The
network is `<compose-project>_default` (`cadence_default` for the README's
minimal stack, `cadence-prod_default` for `docker-compose.yml`):

```bash
docker run … --network cadence-prod_default -e CAD_SERVER_URL=http://cadence:4000 …
```

or set `CAD_HTTP_BIND=0.0.0.0` on the server and firewall the port. Prove it
from inside the network before blaming the daemon:

```bash
docker run --rm --network cadence-prod_default curlimages/curl -fsS http://cadence:4000/health
```

Two path traps come with the container form. Mount the state directory at the
**same absolute path** inside and outside, and set `CAD_STATE_DIR` to that path:
the SQLite database stores absolute `git_dir` and `work_dir` values, so a
different mount target leaves every registered project pointing at a directory
that does not exist (`eacces` on boot, `project not found` on sync). Project
directories must be mounted at their real paths for the same reason.

## Daemon logs `Unknown CA` or gets a `403`

**Symptom:** the daemon logs
`TLS :client: In state :wait_cert_cr … Fatal - Unknown CA` every few seconds
(the sync channel retries on a 5 s timer) and nothing syncs, although the URL
opens in a browser.
**Cause:** the network is intercepting TLS for the server's hostname. A firewall
with content filtering re-signs the connection with its own certificate, so the
chain does not end at a CA in the image. The same request with verification off
usually returns the appliance's block page (for example
`403 Web Filter Block Override`).
**Fix:** check from the host with `curl -v https://cadence.example.com/health`.
If the chain shows an appliance issuer instead of the server's real one, sync
from a network that does not intercept the domain, or add that appliance's CA to
the daemon's trust store (`/etc/ssl/certs` in the image). Cadence cannot tunnel
through the filter.

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

- [DEPLOY.md](DEPLOY.md): layouts, backup/restore, upgrades.
- [README.md](README.md): project overview and local demo.
