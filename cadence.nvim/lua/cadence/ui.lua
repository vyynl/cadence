local M = {}

local FLAG_HL = {
  ["functioning"] = "CadenceFunctioning",
  ["in-progress"] = "CadenceInProgress",
  ["broken"] = "CadenceBroken",
  ["sandbox"] = "CadenceSandbox",
}

local function set_hl(group, fg, extra)
  local spec = vim.tbl_extend("force", { fg = fg, default = true }, extra or {})
  vim.api.nvim_set_hl(0, group, spec)
end

--- Define the picker's highlight groups (idempotent).
M.setup_highlights = function()
  set_hl("CadenceFunctioning", "#98c379")
  set_hl("CadenceInProgress", "#e5c07b")
  set_hl("CadenceBroken", "#e06c75")
  set_hl("CadenceSandbox", "#61afef")
  set_hl("CadencePinned", "#c678dd", { bold = true, underline = true })
  set_hl("CadenceEdge", "#5c6370")
  set_hl("CadenceDiffHeader", "#61afef", { bold = true })
  set_hl("CadenceDiffAdd", "#98c379", { bg = "#22331f" })
  set_hl("CadenceDiffDelete", "#e06c75", { bg = "#3a2426" })
  set_hl("CadenceDiffMeta", "#5c6370", { italic = true })
end

-- Backwards-compatible simple list (kept for any non-graph caller).
M.open = function(title, items, on_select)
  if #items == 0 then
    items = { "(none)" }
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, items)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

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

local function short_id(id)
  if not id then
    return "-"
  end
  return id:sub(1, 8)
end

local function flags_text(flags)
  if not flags or #flags == 0 then
    return "-"
  end
  return table.concat(flags, ", ")
end

local function wrap(text, width)
  local out = {}
  text = (text or ""):gsub("\r", "")
  for _, raw in ipairs(vim.split(text, "\n", { plain = true })) do
    if raw == "" then
      out[#out + 1] = ""
    else
      local line = ""
      for _, word in ipairs(vim.split(raw, "%s+", { trimempty = true })) do
        if line == "" then
          line = word
        elseif #line + 1 + #word <= width then
          line = line .. " " .. word
        else
          out[#out + 1] = line
          line = word
        end
      end
      if line ~= "" then
        out[#out + 1] = line
      end
    end
  end
  return out
end

--- Open the DAG picker.
---
--- `layout` is the output of `cadence.graph.layout/3`. `opts`:
---   title, default_node_id, on_switch(node_id), union (boolean)
M.open_graph = function(layout, opts)
  opts = opts or {}
  M.setup_highlights()

  local graph = require("cadence.graph")
  local cfg = (require("cadence").config or {}).graph or {}

  local ratio = cfg.width_ratio or 0.2
  local rail_w = math.floor(vim.o.columns * ratio)
  rail_w = math.max(rail_w, cfg.min_width or 20)
  rail_w = math.min(rail_w, cfg.max_width or 60)
  rail_w = math.min(rail_w, vim.o.columns - 2)

  local graph_lines = layout.lines
  if #graph_lines == 0 then
    graph_lines = { "(no nodes yet)" }
  end

  local union = opts.union == true
  local selected = {}
  local ns = vim.api.nvim_create_namespace("cadence_graph")
  local union_ns = vim.api.nvim_create_namespace("cadence_union")
  local diff_ns = vim.api.nvim_create_namespace("cadence_diff_panel")
  local diff_cache = {}

  local lines = {}
  for i, l in ipairs(graph_lines) do
    lines[i] = l
  end
  local footer_idx = nil
  if union then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "selected 0 · <C-s> submit"
    footer_idx = #graph_lines + 1
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "cadence"
  vim.bo[buf].bufhidden = "wipe"

  local rail_h = math.min(math.max(#lines, 1), vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = rail_w,
    height = rail_h,
    row = 1,
    col = 0,
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "cadence") .. " ",
    title_pos = "left",
  })
  vim.wo[win].wrap = false

  -- Node and edge highlights.
  for _, cell in pairs(layout.nodes) do
    local group = FLAG_HL[cell.flag or ""] or "CadenceEdge"
    vim.api.nvim_buf_set_extmark(buf, ns, cell.row, cell.col, {
      end_col = cell.col + 1,
      hl_group = group,
    })
    if cell.pinned then
      vim.api.nvim_buf_set_extmark(buf, ns, cell.row, cell.col, {
        end_col = cell.col + 1,
        hl_group = "CadencePinned",
        priority = 10,
      })
    end
  end
  for _, ec in ipairs(layout.edge_cells or {}) do
    local group = FLAG_HL[ec.flag or ""] or "CadenceEdge"
    vim.api.nvim_buf_set_extmark(buf, ns, ec.row, ec.col, {
      end_col = ec.col + 1,
      hl_group = group,
    })
  end

  -- Hover panel (metadata + message; the diff preview arrives later).
  local panel = { win = nil, buf = nil }

  local function close_panel()
    if panel.win and vim.api.nvim_win_is_valid(panel.win) then
      vim.api.nvim_win_close(panel.win, true)
    end
    panel.win, panel.buf = nil, nil
  end

  local function close_all()
    close_panel()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function cursor_cell()
    local cur = vim.api.nvim_win_get_cursor(win)
    local id = graph.node_at(layout.nodes, cur[1] - 1, cur[2])
    return id and layout.nodes[id] or nil
  end

  -- A node's diff block, fetched on demand and cached. `false` means "no diff
  -- available" (so we don't refetch on every cursor move).
  local function diff_block(node_id)
    if diff_cache[node_id] ~= nil then
      return diff_cache[node_id]
    end

    local payload = opts.diff_fetcher and opts.diff_fetcher(node_id) or nil
    local formatted = payload and require("cadence.diff").format(payload) or false
    diff_cache[node_id] = formatted
    return formatted
  end

  local function panel_lines(cell, width)
    local out, hl = {}, {}

    local function push(text, group)
      out[#out + 1] = text
      if group then
        hl[#out] = group
      end
    end

    push("committer  " .. short_id(cell.created_by))
    push("date       " .. (cell.created_at or "-"))
    push("flags      " .. flags_text(cell.flags) .. (cell.pinned and "  ★" or ""))
    push("")

    for _, l in ipairs(wrap(cell.message or "(no message)", width)) do
      push(l)
    end

    local block = diff_block(cell.id)
    if block then
      push("")
      for i, l in ipairs(block.lines) do
        push(l, block.hl[i])
      end
    end

    return out, hl
  end

  local update_panel
  update_panel = function()
    local cell = cursor_cell()
    if not cell then
      close_panel()
      return
    end

    local pw = math.min(vim.o.columns - rail_w - 3, 90)
    if pw < 20 then
      pw = math.max(vim.o.columns - rail_w - 3, 10)
    end
    local plines, phl = panel_lines(cell, pw)
    local ph = math.min(#plines, vim.o.lines - 4)

    if panel.win and vim.api.nvim_win_is_valid(panel.win) then
      vim.api.nvim_win_set_config(panel.win, { width = pw, height = ph })
    else
      panel.buf = vim.api.nvim_create_buf(false, true)
      vim.bo[panel.buf].bufhidden = "wipe"
      panel.win = vim.api.nvim_open_win(panel.buf, false, {
        relative = "editor",
        width = pw,
        height = ph,
        row = 1,
        col = rail_w + 2,
        style = "minimal",
        border = "rounded",
        title = " " .. short_id(cell.id) .. " ",
        title_pos = "left",
      })
      vim.keymap.set("n", "<Tab>", function()
        vim.api.nvim_set_current_win(win)
      end, { buffer = panel.buf })
      vim.keymap.set("n", "q", close_all, { buffer = panel.buf })
      vim.keymap.set("n", "<Esc>", close_all, { buffer = panel.buf })
    end

    vim.bo[panel.buf].modifiable = true
    vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, plines)
    vim.bo[panel.buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(panel.buf, diff_ns, 0, -1)
    for i, group in pairs(phl) do
      vim.api.nvim_buf_set_extmark(panel.buf, diff_ns, i - 1, 0, {
        end_row = i,
        end_col = 0,
        hl_group = group,
        hl_eol = true,
      })
    end
  end

  local function move(dir)
    local cell = cursor_cell()
    if not cell then
      return
    end
    local nid = graph.nearest(layout.nodes, cell.id, dir)
    if nid then
      local c = layout.nodes[nid]
      vim.api.nvim_win_set_cursor(win, { c.row + 1, c.col })
      update_panel()
    end
  end

  local nav = {
    h = "left",
    l = "right",
    k = "up",
    j = "down",
    ["<Left>"] = "left",
    ["<Right>"] = "right",
    ["<Up>"] = "up",
    ["<Down>"] = "down",
  }
  for lhs, dir in pairs(nav) do
    vim.keymap.set("n", lhs, function()
      move(dir)
    end, { buffer = buf })
  end

  local function refresh_footer()
    if not union or not footer_idx then
      return
    end
    local n = 0
    for _ in pairs(selected) do
      n = n + 1
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, footer_idx, footer_idx + 1, false, {
      string.format("selected %d · <C-s> submit", n),
    })
    vim.bo[buf].modifiable = false
  end

  local function toggle(node_id, cell)
    if selected[node_id] then
      vim.api.nvim_buf_del_extmark(buf, union_ns, selected[node_id])
      selected[node_id] = nil
    else
      selected[node_id] = vim.api.nvim_buf_set_extmark(buf, union_ns, cell.row, cell.col, {
        virt_text = { { "✓", "CadencePinned" } },
        virt_text_pos = "overlay",
      })
    end
    refresh_footer()
  end

  vim.keymap.set("n", "<CR>", function()
    local cell = cursor_cell()
    if not cell then
      return
    end
    if union then
      toggle(cell.id, cell)
    else
      close_all()
      if opts.on_switch then
        opts.on_switch(cell.id)
      end
    end
  end, { buffer = buf })

  vim.keymap.set("n", "<Tab>", function()
    local cell = cursor_cell()
    if not cell then
      return
    end
    update_panel()
    if panel.win and vim.api.nvim_win_is_valid(panel.win) then
      vim.api.nvim_set_current_win(panel.win)
    end
  end, { buffer = buf })

  vim.keymap.set("n", "<C-s>", function()
    vim.notify("union requires the server (Phase 2b)", vim.log.levels.WARN)
  end, { buffer = buf })

  vim.keymap.set("n", "q", close_all, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close_all, { buffer = buf })

  -- Move the cursor to the default node, then populate the hover panel.
  local start = graph.default_id(layout.nodes, opts.default_node_id)
  if start then
    local c = layout.nodes[start]
    vim.api.nvim_win_set_cursor(win, { c.row + 1, c.col })
  end
  update_panel()

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = update_panel,
  })

  return win, buf
end

return M
