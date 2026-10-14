-- Headless unit tests for the pure layout module.
-- Run: nvim --headless -l cadence.nvim/spec/graph_spec.lua
--   or: luajit cadence.nvim/spec/graph_spec.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = here:gsub("/spec/.*$", "")
package.path = root .. "/lua/?.lua;" .. package.path

local graph = require("cadence.graph")

local failures = 0

local function check(name, cond)
  if cond then
    io.write("  ok   ", name, "\n")
  else
    io.write("  FAIL ", name, "\n")
    failures = failures + 1
  end
end

local function eq(name, actual, expected)
  check(name .. " (" .. tostring(actual) .. " == " .. tostring(expected) .. ")", actual == expected)
end

local function node(id, depth, parents, opts)
  opts = opts or {}
  return {
    id = id,
    depth = depth,
    parents = parents or {},
    flags = opts.flags or { "in-progress" },
    pinned = opts.pinned or false,
    message = opts.message or ("msg-" .. id),
    created_at = opts.created_at or ("2026-01-0" .. tostring(depth + 1) .. "T00:00:00Z"),
    created_by = opts.created_by or "user",
  }
end

-- linear -------------------------------------------------------------------
do
  io.write("linear\n")
  local nodes = {
    node("a", 0),
    node("b", 1, { "a" }),
    node("c", 2, { "b" }),
  }
  local edges = { { from = "a", to = "b" }, { from = "b", to = "c" } }
  local g = graph.layout(nodes, edges)

  eq("height", g.height, 5)
  eq("a row", g.nodes.a.row, 0)
  eq("b row", g.nodes.b.row, 2)
  eq("c row", g.nodes.c.row, 4)
  eq("single column", g.nodes.a.col, 0)
  eq("line 1", g.lines[1], "●")
  eq("line 2", g.lines[2], "|")
  eq("line 3", g.lines[3], "●")
  eq("line 4", g.lines[4], "|")
  eq("line 5", g.lines[5], "●")
end

-- branch + navigation ------------------------------------------------------
do
  io.write("branch\n")
  local nodes = {
    node("a", 0),
    node("b", 1, { "a" }, { created_at = "2026-01-01T00:00:00Z" }),
    node("c", 1, { "a" }, { flags = { "broken" }, created_at = "2026-01-02T00:00:00Z" }),
  }
  local edges = { { from = "a", to = "b" }, { from = "a", to = "c" } }
  local g = graph.layout(nodes, edges)

  eq("b before c", g.nodes.b.col < g.nodes.c.col, true)
  eq("siblings same row", g.nodes.b.row == g.nodes.c.row, true)

  eq("right of b is c", graph.nearest(g.nodes, "b", "right"), "c")
  eq("left of c is b", graph.nearest(g.nodes, "c", "left"), "b")
  eq("down from a is b", graph.nearest(g.nodes, "a", "down"), "b")
  eq("up from c is a", graph.nearest(g.nodes, "c", "up"), "a")
  eq("no right of c", graph.nearest(g.nodes, "c", "right"), nil)

  eq("node_at b cell", graph.node_at(g.nodes, g.nodes.b.row, g.nodes.b.col), "b")

  local tagged = false
  for _, ec in ipairs(g.edge_cells) do
    if ec.flag == "broken" then
      tagged = true
    end
  end
  eq("edge tagged with child flag", tagged, true)
end

-- meld (adjacent layers) ---------------------------------------------------
do
  io.write("meld\n")
  local nodes = {
    node("r", 0),
    node("x", 1, { "r" }),
    node("y", 1, { "r" }, { created_at = "2026-01-05T00:00:00Z" }),
    node("m", 2, { "x", "y" }),
  }
  local edges = {
    { from = "r", to = "x" },
    { from = "r", to = "y" },
    { from = "x", to = "m" },
    { from = "y", to = "m" },
  }
  local g = graph.layout(nodes, edges)
  eq("m row", g.nodes.m.row, 4)

  local incoming = 0
  for _, ec in ipairs(g.edge_cells) do
    if ec.row == 3 then
      incoming = incoming + 1
    end
  end
  eq("two glyphs in m's edge row", incoming >= 2, true)
end

-- default + pinned + empty -------------------------------------------------
do
  io.write("default/pinned/empty\n")
  local nodes = {
    node("a", 0, {}, { pinned = true }),
    node("b", 1, { "a" }),
  }
  local g = graph.layout(nodes, { { from = "a", to = "b" } })

  eq("pinned glyph", g.lines[1], "◉")
  eq("default top-left", graph.default_id(g.nodes, nil), "a")
  eq("default prefers given", graph.default_id(g.nodes, "b"), "b")

  local empty = graph.layout({}, {})
  eq("empty count", empty.count, 0)
end

-- wrap ---------------------------------------------------------------------
do
  io.write("wrap\n")
  local nodes = {}
  for i = 1, 4 do
    nodes[i] = node("n" .. i, 0, {}, { created_at = string.format("2026-01-0%dT00:00:00Z", i) })
  end

  local flat = graph.layout(nodes, {})
  eq("no wrap -> single row", flat.height, 1)
  eq("no wrap -> all placed", flat.count, 4)

  local g = graph.layout(nodes, {}, { max_cols = 6 })
  eq("wrapped: all placed", g.count, 4)
  eq("wrapped height", g.height, 5)
  eq("break row", g.lines[2]:find("╌", 1, true) ~= nil, true)
  eq("nav crosses wrap", graph.nearest(g.nodes, "n1", "down") ~= nil, true)
end

io.write("\n")
if failures > 0 then
  io.write(failures, " failure(s)\n")
  os.exit(1)
end
io.write("all graph tests passed\n")
os.exit(0)
