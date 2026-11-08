# cadence.nvim

Neovim front-end for the Cadence daemon (spec §13 Phase 1e). Provides `:CadOpen`,
`:CadSpawn`, and `:CadSwitch`, all talking to the daemon over its Unix socket.

## Requirements

- Neovim 0.9+
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- `curl` on `PATH`
- A running Cadence daemon — see `../docs/daemon-setup.md` (token, migration,
  boot command, project registration)

## Install (lazy.nvim)

```lua
{
  "cadence.nvim", -- local dev path, e.g. "~/code/cadence/cadence.nvim"
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("cadence").setup({
      -- socket_path = "/custom/path/daemon.sock", -- optional override
    })
  end,
}
```

The socket path is resolved as: `setup({socket_path})` → `$CAD_STATE_DIR/daemon.sock`
→ `~/.local/state/cadence/daemon.sock`.

## Commands

| Command          | Behavior                                                        |
|------------------|-----------------------------------------------------------------|
| `:CadOpen`       | Open the DAG picker for the current project.                    |
| `:CadSwitch`     | Same picker (Enter moves the session pointer to the node).      |
| `:CadUnion`      | Open the picker in union mode (`CR` toggles `✓`; submission needs the server). |
| `:CadProposals`  | List recent union proposals and copy the chosen public URL (or token when the server URL is unset). |
| `:CadSpawn [name]` | Spawn a `sandbox` child from the current node (prompts if no name). |

## Picker

The DAG renders as a left-aligned rail (`clamp(20% of width, 20, 60)` columns,
configurable via `require("cadence").setup({ graph = { ... } })`).

- `h`/`j`/`k`/`l` (and arrows) move between nodes.
- `<CR>` switches the session pointer to the highlighted node.
- Hovering a node opens a panel with committer, date/time, flags, the commit
  message, and a GitHub-style color-coded diff of the node against its parent
  (added/removed lines, file headers, `…` for collapsed context).
- `<Tab>` enters/leaves the hover panel (e.g. to scroll a long message/diff).
- `q`/`<Esc>` close.

When Neovim starts inside a registered project directory, the picker opens
automatically (spec §6.3). Disable with `setup({ auto_open = false })`.

The "current project" is determined by matching `vim.fn.getcwd()` against the
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
# terminal A — daemon (see docs/daemon-setup.md for token + migration)
mix run --no-start --no-halt -e 'Application.ensure_all_started(:cadence_daemon)'

# terminal B — register a project (work_dir must be an existing directory)
mix cad.register MyProject my-project ~/code/my-project

# terminal C — in ~/code/my-project
nvim
#   :CadOpen       -> DAG rail; hover shows metadata/message; <CR> switches
#   :CadSpawn      -> spawns a sandbox child, then :CadOpen shows it branched
#   :CadSwitch     -> same picker, titled "switch"
#   :CadUnion      -> picker in union mode (CR toggles ✓)
#   :CadProposals  -> list recent unions; choose one to copy its public URL
```

Run the pure-Lua unit tests (no daemon needed):

```bash
nvim --headless -l cadence.nvim/spec/graph_spec.lua
nvim --headless -l cadence.nvim/spec/diff_spec.lua
nvim --headless -l cadence.nvim/spec/doc_spec.lua
nvim --headless -l cadence.nvim/spec/proposal_spec.lua
```

Note: a normal commit advances the session pointer automatically (spec §5.3), so
`:CadSpawn` works immediately after any commit.
