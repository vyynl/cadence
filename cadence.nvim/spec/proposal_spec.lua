-- Headless unit tests for the pure proposal-command helpers.
-- Run: nvim --headless -l cadence.nvim/spec/proposal_spec.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = here:gsub("/spec/.*$", "")
package.path = root .. "/lua/?.lua;" .. package.path

local proposal = require("cadence.proposal")

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

-- kinds ----------------------------------------------------------------------
do
  io.write("kinds\n")
  eq("meld title", proposal.kind_title("meld"), "Meld")
  eq("promotion title", proposal.kind_title("promotion"), "Promotion")
  eq("unknown kind", proposal.kind_title("weird"), "Proposal")
  eq("nil kind", proposal.kind_title(nil), "Proposal")
  eq("non-string kind", proposal.kind_title(7), "Proposal")
end

-- age ------------------------------------------------------------------------
do
  io.write("age\n")
  eq("zero", proposal.age(0), "just now")
  eq("59s", proposal.age(59), "just now")
  eq("60s", proposal.age(60), "1m")
  eq("3599s", proposal.age(3599), "59m")
  eq("3600s", proposal.age(3600), "1h")
  eq("86399s", proposal.age(86399), "23h")
  eq("86400s", proposal.age(86400), "1d")
  eq("negative", proposal.age(-1), "unknown")
  eq("nil", proposal.age(nil), "unknown")
  eq("string", proposal.age("12"), "unknown")
end

-- item formatting ------------------------------------------------------------
do
  io.write("format_item\n")
  local item = {
    kind = "meld",
    token = "abcdefghijklmnop",
    parent_node_ids = { "a", "b" },
    age_seconds = 7200,
  }
  eq("full item", proposal.format_item(item), "Meld · 2 parents · 2h · abcdefghij")

  local single = {
    kind = "promotion",
    token = "tok",
    parent_node_ids = { "a" },
    age_seconds = 10,
  }
  eq("singular parent", proposal.format_item(single), "Promotion · 1 parent · just now · tok")

  local bare = { kind = "meld" }
  eq("missing fields", proposal.format_item(bare), "Meld · 0 parents · unknown · unknown")

  eq("nil item", proposal.format_item(nil), "Proposal · 0 parents · unknown · unknown")
end

-- copy target ----------------------------------------------------------------
do
  io.write("copy target\n")
  local url = proposal.target({ url = "http://server/proposals/tok", token = "tok" })
  eq("url kind", url.kind, "url")
  eq("url value", url.value, "http://server/proposals/tok")

  local token = proposal.target({ url = nil, token = "tok" })
  eq("token kind", token.kind, "token")
  eq("token value", token.value, "tok")

  local none = proposal.target({})
  eq("none kind", none.kind, "none")
  eq("none value", none.value, nil)

  local empty = proposal.target({ url = "", token = "" })
  eq("empty kind", empty.kind, "none")
end

-- notifications --------------------------------------------------------------
do
  io.write("copy result\n")
  local copied = proposal.copy_result({ kind = "url", value = "http://server/proposals/tok" })
  eq("url level", copied.level, "info")
  eq("url message", copied.message, "copied proposal URL: http://server/proposals/tok")

  local offline = proposal.copy_result({ kind = "token", value = "tok" })
  eq("token level", offline.level, "warn")
  eq("token message", offline.message, "server URL not configured; copied token: tok")

  local none = proposal.copy_result({ kind = "none", value = nil })
  eq("none level", none.level, "warn")
  eq("none message", none.message, "this proposal has no URL or token")

  check("nil target", proposal.copy_result(nil) ~= nil)
end

io.write("\n")
if failures > 0 then
  io.write(failures, " failure(s)\n")
  os.exit(1)
end
io.write("all proposal tests passed\n")
os.exit(0)
