-- Root entrypoint so the monorepo itself is installable as a Neovim plugin.
-- Package managers source plugin/ from the repository root; load the real
-- command definitions from cadence.nvim/.
local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")
dofile(root .. "/cadence.nvim/plugin/cadence.lua")
