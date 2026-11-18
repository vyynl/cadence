# Cadence daemon

The daemon is the local half of Cadence. It watches registered project
directories, commits debounced snapshots to a local Git store, serves the
Neovim plugin over a Unix socket, and pushes those nodes to a Cadence server.

The container form stores its settings with the `setup` command (below); the
compose and release forms read environment variables, annotated in
[`.env.daemon.example`](.env.daemon.example). No variable is repeated here.

## Install

### Container (setup command)

```bash
STATE="$HOME/.local/state/cadence"
mkdir -p "$STATE"
docker run --rm -it --user "$(id -u):$(id -g)" \
  -v "$STATE:$STATE" -e CAD_STATE_DIR="$STATE" \
  ghcr.io/vyynl/cadence-daemon:latest setup

docker run -d --name cadence-daemon --restart unless-stopped \
  --user "$(id -u):$(id -g)" --network cadence-prod_default \
  -v "$STATE:$STATE" -e CAD_STATE_DIR="$STATE" \
  -v /path/to/project:/path/to/project \
  ghcr.io/vyynl/cadence-daemon:latest
```

`setup` asks for the server URL and the API token from `/auth/tokens/new`,
writes both to `$STATE/daemon.env` (mode 0600, inside the volume) and migrates
the database. No secret appears in a `docker run -e` flag, in shell history, or
in `docker inspect`. The second command reads that file, migrates if needed and
starts the daemon, with the socket at `$STATE/daemon.sock`, which is where the plugin
already looks.

Create `$STATE` on the host first and pass the same `--user` to both commands.
Docker creates a missing bind-mount directory as `root`, and a setup run as the
image's uid 10000 would leave files the `--user` daemon cannot read.

Reach a local server by service name, not `localhost`: `http://cadence:4000` on
the server stack's network (`cadence-prod_default` for `docker-compose.yml`,
`cadence_default` for the README's minimal stack). For a remote server, drop
`--network` and enter its public origin.

Mount the state directory at the **same path** on both sides: the database
stores absolute paths. Add one `-v /host/path:/same/host/path` per project.
Drop `--network` for a remote server. To upgrade: `docker pull`,
`docker rm -f cadence-daemon`, re-run the second command.

### Compose (declarative, many projects)

`docker-compose.daemon.yml` uses `env_file: required: false`, so it needs
**Docker Compose 2.24 or newer**; older releases reject that key.

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
work locally and nothing syncs. A server is a prerequisite; see
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

## Terminal UI

`mix cad.tui` is a keyboard-driven frontend over the same daemon socket, so it
works from a shell without Neovim and over SSH. It is a pure socket client: it
never starts the daemon, opens the database, or reads the Git store, so the
daemon must already be running and its `daemon.sock` must be reachable.

```bash
mix cad.tui                        # --project, then cwd match, then a picker
mix cad.tui --project my-project   # slug or id
mix cad.tui --socket /run/cadence/daemon.sock --refresh 2000
```

| Key | Action |
|---|---|
| `h` `j` `k` `l` / arrows | move through the DAG |
| `Enter` | switch the session pointer to the selected node |
| `s` | spawn a session from the current node |
| `u` | union mode: `Enter` toggles a parent, `S` submits, `Esc` cancels |
| `p` | proposals: `j`/`k` selects, `y` copies the URL (OSC 52) |
| `d` / `D` | node diff / docs diff for the selected node |
| `J` / `K` | scroll the diff |
| `g` | queue docs sync for the selected node |
| `r` | refresh the graph and project list |
| `?` | help |
| `q` / `Esc` | quit (`Esc` closes an overlay first) |

Copying a proposal URL uses OSC 52, so it reaches the terminal you are typing
in, including through SSH.

From a release install the same UI starts through the release binary, with a
TTY attached:

```bash
bin/cadence_daemon eval 'Cadence.Daemon.TUI.main()'
docker compose -f docker-compose.daemon.yml exec daemon \
  /app/bin/cadence_daemon eval 'Cadence.Daemon.TUI.main()'
```

The TUI only speaks endpoints that exist on the daemon it connects to, so keep
the daemon at least as new as the TUI.

## Troubleshooting

- **Daemon not syncing.** Check `CAD_SERVER_URL` reachability from the daemon's
  network namespace and that `CAD_SYNC_ENABLED` is not false.
- **Auth fails.** Mint a new token at `/auth/tokens/new`, put it in
  `CAD_AUTH_TOKEN`, and restart the daemon. Tokens are shown once and the server
  stores only a hash; a new token replaces the old one for the daemon, but the
  old row must be removed at the database level until a revoke control ships.
- **Watcher missing deps.** `fs_inotify` needs `inotifywait` (`inotify-tools`);
  the image ships it, host installs may not. On any platform set
  `CAD_WATCH_BACKEND=fs_poll`.

## See also

- [`DEPLOY.md`](DEPLOY.md): the server the daemon syncs to.
- [`README.md`](README.md): what Cadence is and how the pieces fit.
