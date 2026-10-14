-- Pure DAG layout for the Neovim picker.
--
-- Consumes the structural graph from the daemon (`GET /graph`: nodes with
-- `depth`/`parents`/`flags`, plus `edges`) and turns it into a character grid
-- for a narrow, left-aligned rail. No `vim.*` here, so it can be unit-tested
-- headlessly (`nvim --headless -l spec/graph_spec.lua` or `luajit`).
--
-- Grid: each layer gets a node row; an edge row sits between layers. When
-- `max_cols` is given, a layer wider than that wraps into stacked sub-rows
-- separated by a break-marker row (spec §7.3). By default (`max_cols` nil) the
-- grid is left unbounded and the rail scrolls horizontally instead.
--
-- A node is `●` (or `◉` when pinned).

local M = {}

-- Highlight precedence when a node carries several flags.
local FLAG_PRIORITY = { "broken", "in-progress", "sandbox", "functioning" }

-- For merging overlapping edge glyphs: keep the most "structural" one.
local GLYPH_RANK = { ["|"] = 3, ["\\"] = 2, ["/"] = 2, ["-"] = 1 }

local BREAK_MARKER = "╌"

local function primary_flag(node)
  local present = {}
  for _, f in ipairs(node.flags or {}) do
    present[f] = true
  end
  for _, f in ipairs(FLAG_PRIORITY) do
    if present[f] then
      return f
    end
  end
  return nil
end

local function sort_by_created(nodes)
  table.sort(nodes, function(a, b)
    local at, bt = a.created_at or "", b.created_at or ""
    if at ~= bt then
      return at < bt
    end
    return (a.id or "") < (b.id or "")
  end)
end

--- Lay out `nodes` (from /graph) and `edges` into a character grid.
---
--- Options:
---   :step      horizontal spacing between nodes (default 3)
---   :max_cols  wrap layers wider than this into sub-rows (default nil = no wrap)
---
--- Returns:
---   lines       array of strings, row 0..height-1 (trailing spaces trimmed)
---   width/height
---   nodes       id -> { row, col, flag, flags, pinned, message, created_at, created_by }
---   edge_cells  array of { row, col, flag } (tagged with the child's flag)
---   max_depth
function M.layout(nodes, edges, opts)
  opts = opts or {}
  local step = opts.step or 3
  local max_cols = opts.max_cols
  if max_cols and max_cols < step then
    max_cols = nil
  end

  local by_id = {}
  local layers = {}
  local max_depth = 0
  for _, n in ipairs(nodes) do
    by_id[n.id] = n
    local d = n.depth or 0
    layers[d] = layers[d] or {}
    table.insert(layers[d], n)
    if d > max_depth then
      max_depth = d
    end
  end

  -- Pack a layer's nodes into one or more bands (each band fits within
  -- max_cols). Without max_cols, a single band keeps the absolute columns.
  local function pack(layer, desired)
    local bands = {}
    local band, prev = {}, -step

    for _, n in ipairs(layer) do
      local want = math.floor((desired[n.id] or 0) + 0.5)
      if want < 0 then
        want = 0
      end
      if max_cols and want > max_cols - step then
        want = max_cols - step
      end

      local col = prev + step
      if want > col then
        col = want
      end

      if max_cols and col > max_cols - step and #band > 0 then
        bands[#bands + 1] = band
        band, prev = {}, -step
        col = want
      end

      band[#band + 1] = { id = n.id, col = col }
      prev = col
    end

    if #band > 0 then
      bands[#bands + 1] = band
    end
    return bands
  end

  local placed = {}
  local cells = {}
  local break_rows = {}
  local row = 0
  local placed_count = 0

  for d = 0, max_depth do
    local layer = layers[d] or {}
    local desired = {}

    if d == 0 then
      sort_by_created(layer)
      for i, n in ipairs(layer) do
        desired[n.id] = (i - 1) * step
      end
    else
      for _, n in ipairs(layer) do
        local sum, count = 0, 0
        for _, parent_id in ipairs(n.parents or {}) do
          local pc = placed[parent_id]
          if pc then
            sum = sum + pc.col
            count = count + 1
          end
        end
        desired[n.id] = count > 0 and (sum / count) or 0
      end

      table.sort(layer, function(a, b)
        local da, db = desired[a.id], desired[b.id]
        if da ~= db then
          return da < db
        end
        local at, bt = a.created_at or "", b.created_at or ""
        if at ~= bt then
          return at < bt
        end
        return (a.id or "") < (b.id or "")
      end)
    end

    for bi, band in ipairs(pack(layer, desired)) do
      if bi > 1 then
        break_rows[row] = true
        row = row + 1
      end

      for _, item in ipairs(band) do
        local n = by_id[item.id]
        placed[n.id] = { row = row, col = item.col }
        cells[n.id] = {
          id = n.id,
          row = row,
          col = item.col,
          flag = primary_flag(n),
          flags = n.flags or {},
          pinned = n.pinned == true,
          message = n.message,
          created_at = n.created_at,
          created_by = n.created_by,
        }
        placed_count = placed_count + 1
      end

      row = row + 1
    end

    -- Reserve an edge row between layers.
    if d < max_depth then
      row = row + 1
    end
  end

  local grid = {}
  local edge_cells = {}

  local function set(r, c, glyph, flag)
    grid[r] = grid[r] or {}
    local existing = grid[r][c]
    if existing == nil then
      grid[r][c] = glyph
      table.insert(edge_cells, { row = r, col = c, flag = flag })
    elseif (GLYPH_RANK[glyph] or 0) > (GLYPH_RANK[existing] or 0) then
      grid[r][c] = glyph
      table.insert(edge_cells, { row = r, col = c, flag = flag })
    end
  end

  for _, e in ipairs(edges) do
    local parent = cells[e.from]
    local child = cells[e.to]

    if parent and child and child.row > parent.row then
      local er = child.row - 1
      local flag = child.flag

      -- Vertical connector for any gap (a wrapped parent spans rows).
      for r = parent.row + 1, er - 1 do
        set(r, parent.col, "|", flag)
      end

      if parent.col == child.col then
        set(er, child.col, "|", flag)
      else
        local s = child.col > parent.col and 1 or -1
        set(er, parent.col, s > 0 and "\\" or "/", flag)

        local a, b = parent.col + s, child.col - s
        local lo, hi = math.min(a, b), math.max(a, b)
        for c = lo, hi do
          set(er, c, "-", flag)
        end

        set(er, child.col, "|", flag)
      end
    end
  end

  -- Overlay node dots last.
  for _, cell in pairs(cells) do
    grid[cell.row] = grid[cell.row] or {}
    grid[cell.row][cell.col] = cell.pinned and "◉" or "●"
  end

  local max_col = 0
  for _, cell in pairs(cells) do
    if cell.col > max_col then
      max_col = cell.col
    end
  end
  for _, ec in ipairs(edge_cells) do
    if ec.col > max_col then
      max_col = ec.col
    end
  end

  local width = max_col + 1
  local lines = {}

  for r = 0, row - 1 do
    local grow = grid[r] or {}
    local parts = {}
    for c = 0, width - 1 do
      local glyph = grow[c]
      if glyph == nil and break_rows[r] then
        glyph = BREAK_MARKER
      end
      parts[c + 1] = glyph or " "
    end
    lines[r + 1] = (table.concat(parts, ""):gsub("%s+$", ""))
  end

  return {
    lines = lines,
    width = width,
    height = row,
    nodes = cells,
    edge_cells = edge_cells,
    max_depth = max_depth,
    count = placed_count,
  }
end

--- The node occupying cell `(row, col)` (both 0-indexed), or nil.
function M.node_at(nodes, row, col)
  for id, cell in pairs(nodes) do
    if cell.row == row and cell.col == col then
      return id
    end
  end
  return nil
end

--- The nearest node in `dir` ("up" | "down" | "left" | "right") from `from_id`.
--- Up/down cross rows (nearest row, then nearest column); left/right stay within
--- the same row. Returns a node id or nil.
function M.nearest(nodes, from_id, dir)
  local from = nodes[from_id]
  if not from then
    return nil
  end

  local best, best_score = nil, nil

  for id, cell in pairs(nodes) do
    if id ~= from_id then
      local score = nil

      if dir == "down" and cell.row > from.row then
        score = (cell.row - from.row) * 1000 + math.abs(cell.col - from.col)
      elseif dir == "up" and cell.row < from.row then
        score = (from.row - cell.row) * 1000 + math.abs(cell.col - from.col)
      elseif dir == "right" and cell.row == from.row and cell.col > from.col then
        score = cell.col - from.col
      elseif dir == "left" and cell.row == from.row and cell.col < from.col then
        score = from.col - cell.col
      end

      if score and (best_score == nil or score < best_score) then
        best, best_score = id, score
      end
    end
  end

  return best
end

--- The node to start on: `preferred` if present, else the top-left-most node.
function M.default_id(nodes, preferred)
  if preferred and nodes[preferred] then
    return preferred
  end

  local best, best_key = nil, nil
  for id, cell in pairs(nodes) do
    local key = cell.row * 10000 + cell.col
    if best_key == nil or key < best_key then
      best, best_key = id, key
    end
  end
  return best
end

return M
