-- Headless unit tests for the pure diff formatter.
-- Run: nvim --headless -l cadence.nvim/spec/diff_spec.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = here:gsub("/spec/.*$", "")
package.path = root .. "/lua/?.lua;" .. package.path

local diff = require("cadence.diff")

local failures = 0

local function eq(name, actual, expected)
  if actual == expected then
    io.write("  ok   ", name, "\n")
  else
    io.write("  FAIL ", name, " (got " .. tostring(actual) .. ", want " .. tostring(expected) .. ")\n")
    failures = failures + 1
  end
end

local function check(name, cond)
  eq(name, not not cond, true)
end

-- modified file ------------------------------------------------------------
do
  io.write("modified\n")
  local res = diff.format({
    files = {
      {
        path = "lib/a.ex",
        status = "modified",
        binary = false,
        truncated = false,
        lines = {
          { kind = "ctx", text = "keep" },
          { kind = "del", text = "old" },
          { kind = "add", text = "new" },
        },
      },
    },
  })

  eq("line count", #res.lines, 4)
  eq("header", res.lines[1], "lib/a.ex  (modified)")
  eq("header hl", res.hl[1], "CadenceDiffHeader")
  eq("ctx line", res.lines[2], "  keep")
  eq("del line", res.lines[3], "- old")
  eq("del hl", res.hl[3], "CadenceDiffDelete")
  eq("add line", res.lines[4], "+ new")
  eq("add hl", res.hl[4], "CadenceDiffAdd")
end

-- skip marker, binary, truncation ------------------------------------------
do
  io.write("markers\n")
  local res = diff.format({
    files = {
      {
        path = "bin",
        status = "added",
        binary = true,
        truncated = false,
        lines = {},
      },
      {
        path = "big",
        status = "modified",
        binary = false,
        truncated = true,
        lines = { { kind = "skip", text = "…" }, { kind = "add", text = "x" } },
      },
    },
    truncated = true,
  })

  local text = table.concat(res.lines, "\n")
  check("binary marker", text:match("%(binary file%)") ~= nil)
  check("skip marker", text:match("  …") ~= nil)
  check("truncated file marker", text:match("%(truncated%)") ~= nil)
  check("files-omitted marker", text:match("more files omitted") ~= nil)
end

-- empty --------------------------------------------------------------------
do
  io.write("empty\n")
  local res = diff.format(nil)
  eq("no changes", res.lines[1], "(no changes)")
end

io.write("\n")
if failures > 0 then
  io.write(failures, " failure(s)\n")
  os.exit(1)
end
io.write("all diff tests passed\n")
os.exit(0)
