-- Pure DAG layout for the Neovim picker.
--
-- Consumes the structural graph from the daemon (`GET /graph`: nodes with
-- `depth`/`parents`/`flags`, plus `edges`) and turns it into a character grid
-- for a narrow, left-aligned rail. No `vim.*` here, so it can be unit-tested
-- headlessly (`nvim --headless -l spec/graph_spec.lua` or `luajit`).
--
-- Grid model: two rows per layer — a node row at `2 * depth` and an edge row at
-- `2 * depth + 1` between layers. A node is `●` (or `◉` when pinned).

local M = {}

-- Highlight precedence when a node carries several flags.
local FLAG_PRIORITY = { "broken", "in-progress", "sandbox", "functioning" }

-- For merging overlapping edge glyphs: keep the most "structural" one.
local GLYPH_RANK = { ["|"] = 3, ["\\"] = 2, ["/"] = 2, ["-"] = 1 }

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
--- Returns a table with:
---   lines       - array of strings, row 0..height-1 (trailing spaces trimmed)
---   width/height
---   nodes       - id -> { row, col, flag, flags, pinned, message, created_at, created_by }
---   edge_cells  - array of { row, col, flag } (edge glyphs, tagged with the child's flag)
---   max_depth
function M.layout(nodes, edges, opts)
  opts = opts or {}
  local step = opts.step or 3

  local layers = {}
  local max_depth = 0
  for _, n in ipairs(nodes) do
    local d = n.depth or 0
    layers[d] = layers[d] or {}
    table.insert(layers[d], n)
    if d > max_depth then
      max_depth = d
    end
  end

  local placed = {} -- id -> { row, col }
  local cells = {} -- id -> cell
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

    local prev = -step
    for _, n in ipairs(layer) do
      local col = math.floor(desired[n.id] + 0.5)
      if col < prev + step then
        col = prev + step
      end
      if col < 0 then
        col = 0
      end

      placed[n.id] = { row = 2 * d, col = col }
      cells[n.id] = {
        id = n.id,
        row = 2 * d,
        col = col,
        flag = primary_flag(n),
        flags = n.flags or {},
        pinned = n.pinned == true,
        message = n.message,
        created_at = n.created_at,
        created_by = n.created_by,
      }
      prev = col
      placed_count = placed_count + 1
    end
  end

  local grid = {} -- grid[row][col] = glyph
  local edge_cells = {}

  local function set(row, col, glyph, flag)
    grid[row] = grid[row] or {}
    local existing = grid[row][col]
    if existing == nil then
      grid[row][col] = glyph
      table.insert(edge_cells, { row = row, col = col, flag = flag })
    elseif (GLYPH_RANK[glyph] or 0) > (GLYPH_RANK[existing] or 0) then
      grid[row][col] = glyph
      table.insert(edge_cells, { row = row, col = col, flag = flag })
    end
  end

  -- Route each edge through the edge row directly above the child. (Local
  -- commits/spawns always link adjacent layers; the server-side meld, which can
  -- span layers, is Phase 4.)
  for _, e in ipairs(edges) do
    local parent = cells[e.from]
    local child = cells[e.to]

    if parent and child and child.row > parent.row then
      local er = child.row - 1
      local flag = child.flag

      if parent.col == child.col then
        set(er, child.col, "|", flag)
      else
        local s = child.col > parent.col and 1 or -1
        set(er, parent.col, s > 0 and "\\" or "/", flag)

        local a, b = parent.col + s, child.col - s
        local lo, hi = math.min(a, b), math.max(a, b)
        for cc = lo, hi do
          set(er, cc, "-", flag)
        end

        set(er, child.col, "|", flag)
      end
    end
  end

  -- Overlay node dots (node rows never collide with edge rows).
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
  local height = 2 * max_depth + 1
  local lines = {}

  for r = 0, height - 1 do
    local row = grid[r] or {}
    local parts = {}
    for c = 0, width - 1 do
      parts[c + 1] = row[c] or " "
    end
    lines[r + 1] = (table.concat(parts, ""):gsub("%s+$", ""))
  end

  return {
    lines = lines,
    width = width,
    height = height,
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
--- Up/down cross layers (nearest row, then nearest column); left/right stay
--- within the same layer. Returns a node id or nil.
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
