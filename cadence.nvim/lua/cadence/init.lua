local M = {}

M.config = {
  socket_path = nil,
  -- Open the picker automatically when Neovim starts inside a project dir.
  auto_open = true,
  graph = {
    -- Rail width = clamp(floor(columns * width_ratio), min_width, max_width).
    width_ratio = 0.2,
    min_width = 20,
    max_width = 60,
    -- Wrap layers wider than this many columns into sub-rows (spec §7.3).
    -- nil (default) leaves the grid unbounded and the rail scrolls instead.
    wrap_width = nil,
  },
}

--- Configure the plugin. Call from your Neovim config:
---   require("cadence").setup({ socket_path = "/tmp/cadence.sock" })
M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  require("cadence.ui").setup_highlights()
end

--- Resolve the daemon Unix socket path.
--- Priority: `setup({socket_path})` → `$CAD_STATE_DIR/daemon.sock` → `~/.local/state/cadence/daemon.sock`.
M.socket_path = function()
  if M.config.socket_path and M.config.socket_path ~= "" then
    return M.config.socket_path
  end

  local state_dir = os.getenv("CAD_STATE_DIR")
    or vim.fn.expand("~/.local/state/cadence")

  return state_dir .. "/daemon.sock"
end

return M
