-- Root entrypoint so the monorepo itself is installable as a Neovim plugin.
--
-- Package managers put the repository root on 'runtimepath'. The plugin source
-- lives in cadence.nvim/ (the same tree used by local `dir =` development), so
-- this shim adds that directory and loads the real module.
local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h:h")
local plugin_dir = root .. "/cadence.nvim"

if not vim.tbl_contains(vim.opt.rtp:get(), plugin_dir) then
  vim.opt.rtp:append(plugin_dir)
end

return dofile(plugin_dir .. "/lua/cadence/init.lua")
