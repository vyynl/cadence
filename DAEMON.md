# Cadence daemon

The daemon is the local half of Cadence. It watches registered project
directories, commits debounced snapshots to a local Git store, serves the
Neovim plugin over a Unix socket, and pushes those nodes to a Cadence server.

Configuration is environment variables only: [`.env.daemon.example`](.env.daemon.example)
is the annotated reference. No variable is repeated here.

## Install

### One command (pull and run)

```bash
mkdir -p "${CAD_STATE_DIR:-$HOME/.local/state/cadence}"
docker run -d --name cadence-daemon --restart unless-stopped \
  --user "$(id -u):$(id -g)" \
  -v "${CAD_STATE_DIR:-$HOME/.local/state/cadence}:/data/state" \
  -e CAD_SERVER_URL=https://cadence.example.com \
  -e CAD_AUTH_TOKEN=cad_replace_with_a_minted_token \
  --entrypoint /bin/sh ghcr.io/vyynl/cadence-daemon:latest \
  -c 'bin/cadence_daemon eval "Cadence.Daemon.Release.migrate()" && exec bin/cadence_daemon start'
```

The image pulls on first run, migrates the state directory, then boots the
daemon. Binding `~/.local/state/cadence` and running as your own uid puts
`daemon.sock` where the plugin already looks, so Neovim needs no extra
configuration. Drop `--user` and swap in `-v cadence-daemon-state:/data/state`
when you want sync only and no local socket. Drop the two `-e` lines to run
offline. Add one `-v /host/path:/same/host/path` per project, mounted at its
real host path. To upgrade: `docker pull`, `docker rm -f cadence-daemon`,
re-run the same command — the state directory survives and the migration
becomes a no-op.

### Compose (declarative, many projects)

```bash
docker compose -f docker-compose.daemon.yml run --rm daemon \
  bin/cadence_daemon eval "Cadence.Daemon.Release.migrate()"
docker compose -f docker-compose.daemon.yml up -d
```

With no `.env.daemon` yet, both commands work offline: the first creates and
migrates the database, the second starts the daemon. Configure below fills in
the server URL and token.

The migration is one-time and after each upgrade; it is safe to repeat and
prints `Migrations already up` when there is nothing to do. A boot before it is
safe but idle, so run it first. Each project directory must be mounted at its
real host path; a different container path is the common failure (see the
commented example in `docker-compose.daemon.yml`).

### Release artifact (host, no Elixir to run it)

```bash
MIX_ENV=prod mix release cadence_daemon      # build on the target OS/arch
_build/prod/rel/cadence_daemon/bin/cadence_daemon eval "Cadence.Daemon.Release.migrate()"
_build/prod/rel/cadence_daemon/bin/cadence_daemon start
```

The release bundles ERTS, so the machine that runs it needs no `mix`, Elixir, or
Erlang. Keep the unpacked directory replaceable and `CAD_STATE_DIR` outside it;
`start` runs in the foreground (use a process manager, or `daemon` to detach).
The release has Erlang distribution off, so stop it with SIGTERM: `stop` and
`remote` do not exist.

## Configure

```bash
[ -f .env.daemon ] || cp .env.daemon.example .env.daemon   # keeps an edited file
$EDITOR .env.daemon                    # CAD_SERVER_URL, CAD_AUTH_TOKEN
chmod 600 .env.daemon
docker compose -f docker-compose.daemon.yml up -d          # container re-reads env_file
set -a; . ./.env.daemon; set +a                            # host release only
```

The token is minted in the server UI at `/auth/tokens/new` and shown once.
Without a URL and token the daemon runs offline: commits, spawns, and switches
work locally and nothing syncs. A server is a prerequisite — see
[`DEPLOY.md`](DEPLOY.md).

If the server runs on this same machine, `CAD_SERVER_URL` still has to be
reachable from the daemon's network namespace: a container daemon cannot use
`localhost:4000`. Join the server's network and use `http://cadence:4000`, and
mount the state directory at the same absolute path so stored paths stay valid.
Both traps are covered in
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#daemon-cannot-reach-the-server).

## Register a project

The daemon must be running, and `WORK_DIR` must be an absolute path that exists
inside the container.

```bash
# container
docker compose -f docker-compose.daemon.yml exec daemon \
  bin/cadence_daemon eval \
  'IO.inspect(Cadence.Daemon.Release.register("My Project", "my-project", "/home/you/code/my-project"))'

# host release, from the release directory
bin/cadence_daemon eval \
  'IO.inspect(Cadence.Daemon.Release.register("My Project", "my-project", "/home/you/code/my-project"))'
```

Registration starts the watcher; the first node appears after a file change and
`CAD_WATCH_DEBOUNCE_MS` of quiet. Registering an unchanged tree produces no
node. From a source checkout the equivalent is `mix cad.register NAME SLUG DIR`;
the same call is `POST /projects` on the daemon socket.

## Neovim

The plugin reads the daemon socket, so it needs a daemon whose `daemon.sock` is
reachable on the host (a host release, or the bind-mount variant commented in
`docker-compose.daemon.yml`). lazy.nvim spec:

```lua
{
  dir = "/home/you/Programming/projects/cadence",
  dependencies = { "nvim-lua/plenary.nvim" },
  lazy = false,
  config = function() require("cadence").setup() end,
}
```

## Troubleshooting

- **Daemon not syncing.** Check `CAD_SERVER_URL` reachability from the daemon's
  network namespace and that `CAD_SYNC_ENABLED` is not false.
- **Auth fails.** Re-issue the token at `/auth/tokens/new` and restart; tokens
  are shown once and revoked tokens fail every request.
- **Watcher missing deps.** `fs_inotify` needs `inotifywait` (`inotify-tools`);
  the image ships it, host installs may not. On any platform set
  `CAD_WATCH_BACKEND=fs_poll`.

## See also

- [`DEPLOY.md`](DEPLOY.md) — the server the daemon syncs to.
- [`README.md`](README.md) — what Cadence is and how the pieces fit.
