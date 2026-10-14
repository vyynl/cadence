local M = {}

M.config = {
  socket_path = nil,
}

--- Configure the plugin. Call from your Neovim config:
---   require("cadence").setup({ socket_path = "/tmp/cadence.sock" })
M.setup = function(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
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
