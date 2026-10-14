# cadence.nvim

Neovim front-end for the Cadence daemon (spec §13 Phase 1e). Provides `:CadOpen`,
`:CadSpawn`, and `:CadSwitch`, all talking to the daemon over its Unix socket.

## Requirements

- Neovim 0.9+
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- `curl` on `PATH`
- A running Cadence daemon (`mix run --no-halt` from the repo root)

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
| `:CadOpen`       | List the current project's nodes in a floating window.          |
| `:CadSpawn [name]` | Spawn a `sandbox` child from the current node (prompts if no name). |
| `:CadSwitch`     | Pick a node and move the session pointer to it.                 |

The "current project" is determined by matching `vim.fn.getcwd()` against the
`work_dir` of registered projects (`GET /projects`). Open Neovim from inside the
project's working directory.

## Manual smoke test

```bash
# terminal A — daemon
mix run --no-halt

# terminal B — register a project (work_dir must be an existing directory)
mix cad.register MyProject my-project ~/code/my-project

# terminal C — in ~/code/my-project
nvim
#   :CadOpen       -> lists nodes
#   :CadSpawn      -> spawns a sandbox child, then :CadOpen shows it
#   :CadSwitch     -> pick a node to move the session pointer
```

Note: a normal commit advances the session pointer automatically (spec §5.3), so
`:CadSpawn` works immediately after any commit.
