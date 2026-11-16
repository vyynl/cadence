# cadence.nvim

Neovim front-end for the Cadence daemon. It talks to the daemon over its Unix
socket and provides the DAG picker plus convenience commands: `:CadOpen`,
`:CadSwitch`, `:CadSpawn`, `:CadUnion`, `:CadProposals`, `:CadDocSync`, and
`:CadDocDiff`.

## Requirements

- Neovim 0.9+
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- `curl` on `PATH`
- A running Cadence daemon — see [daemon setup](../DAEMON.md) for the
  token, migration, boot command, and project registration

## Install

The plugin source lives in `cadence.nvim/`, and the repository root exposes
the standard `lua/` and `plugin/` entrypoints. Install the repository itself;
no separate plugin repository or build step is needed.

### lazy.nvim / LazyVim

Add this to `lua/plugins/cadence.lua` (LazyVim) or your lazy.nvim spec:

```lua
{
  "vyynl/cadence",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("cadence").setup({
      -- socket_path = "/custom/path/daemon.sock", -- optional override
    })
  end,
}
```

### Packer

```lua
use({
  "vyynl/cadence",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("cadence").setup()
  end,
})
```

### vim-plug

```vim
Plug 'nvim-lua/plenary.nvim'
Plug 'vyynl/cadence'
```

Then call `require("cadence").setup()` from your config (optional; the default
configuration works).

### mini.deps

```lua
add({ source = "vyynl/cadence", depends = { "nvim-lua/plenary.nvim" } })
```

### Local development

Point the manager at the plugin subdirectory instead (the root shims are not
involved):

```lua
{
  dir = vim.fn.expand("~/code/cadence/cadence.nvim"),
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("cadence").setup()
  end,
}
```

The socket path is resolved as: `setup({socket_path})` →
`$CAD_STATE_DIR/daemon.sock` → `~/.local/state/cadence/daemon.sock`.

## Commands

| Command | Behavior |
|---|---|
| `:CadOpen` | Open the DAG picker for the current project. |
| `:CadSwitch` | Open the same picker; `<CR>` moves the session pointer to the node. |
| `:CadSpawn [name]` | Spawn a `sandbox` child from the current node (prompts if no name). |
| `:CadUnion` | Open the picker in union mode (`<CR>` toggles `✓`; submission needs the server). |
| `:CadProposals` | List recent union proposals and copy the chosen public URL (or token when the server URL is unset). |
| `:CadDocSync [node]` | Trigger documentation automation for the current or named node. |
| `:CadDocDiff [node]` | Show the documentation diff attached to the current or named node. |

## Picker

The DAG renders as a left-aligned rail (`clamp(20% of width, 20, 60)` columns,
configurable through `require("cadence").setup({ graph = { ... } })`).

- `h`/`j`/`k`/`l` (and arrows) move between nodes.
- `<CR>` switches the session pointer to the highlighted node.
- Hovering a node opens a panel with committer, date/time, flags, the commit
  message, and a GitHub-style color-coded diff of the node against its parent
  (added/removed lines, file headers, `…` for collapsed context).
- `<Tab>` enters or leaves the hover panel, for example to scroll a long message
  or diff.
- `q`/`<Esc>` close.

When Neovim starts inside a registered project directory, the picker opens
automatically (`auto_open`, see [architecture](../ARCHITECTURE.md)). Disable
it with `setup({ auto_open = false })`.

The current project is determined by matching `vim.fn.getcwd()` against the
`work_dir` of registered projects (`GET /projects`). Open Neovim from inside the
project's working directory.

### Configuration

```lua
require("cadence").setup({
  auto_open = true,
  graph = {
    width_ratio = 0.2, -- rail width = clamp(cols * ratio, min_width, max_width)
    min_width = 20,
    max_width = 60,
    wrap_width = nil, -- wrap wide layers into sub-rows; nil = scroll instead
  },
})
```

## Manual smoke test

```bash
# terminal A — daemon (see ../DAEMON.md for token and migration)
mix run --no-start --no-halt -e 'Application.ensure_all_started(:cadence_daemon)'

# terminal B — register a project (work_dir must be an existing directory)
mix cad.register MyProject my-project ~/code/my-project

# terminal C — in ~/code/my-project
nvim
#   :CadOpen       -> DAG rail; hover shows metadata/message; <CR> switches
#   :CadSpawn      -> spawns a sandbox child, then :CadOpen shows it branched
#   :CadSwitch     -> same picker, titled "switch"
#   :CadUnion      -> picker in union mode (<CR> toggles ✓)
#   :CadProposals  -> list recent unions; choose one to copy its public URL
#   :CadDocSync    -> queue documentation for the current node
#   :CadDocDiff    -> show the documentation diff, if one exists
```

Run the pure-Lua unit tests (no daemon needed):

```bash
nvim --headless -l cadence.nvim/spec/graph_spec.lua
nvim --headless -l cadence.nvim/spec/diff_spec.lua
nvim --headless -l cadence.nvim/spec/doc_spec.lua
nvim --headless -l cadence.nvim/spec/proposal_spec.lua
nvim --headless -l cadence.nvim/spec/client_spec.lua
```

A normal commit advances the session pointer automatically, so `:CadSpawn`
acts on the new head immediately after a commit.

## Related docs

- [Daemon setup](../DAEMON.md) — install, token, environment, and
  troubleshooting.
- [Architecture](../ARCHITECTURE.md) — DAG, plugin commands, and the sync
  contract.
