local M = {}

--- Open a floating window listing `items` (a list of display strings).
--- Pressing `<CR>` invokes `on_select(row, line)` (if provided); `q`/`<Esc>` closes.
M.open = function(title, items, on_select)
  if #items == 0 then
    items = { "(none)" }
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, items)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "cadence")

  local width = 40
  for _, line in ipairs(items) do
    width = math.max(width, #line)
  end
  width = math.min(width + 4, vim.o.columns - 4)

  local height = math.min(math.max(#items, 1), 15)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = 2,
    col = 2,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.api.nvim_buf_set_keymap(buf, "n", "q", "", { callback = close })
  vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", "", { callback = close })

  if on_select then
    vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", "", {
      callback = function()
        local row = vim.api.nvim_win_get_cursor(win)[1]
        close()
        on_select(row, items[row])
      end,
    })
  end

  return win, buf
end

return M
