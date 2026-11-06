-- Headless unit tests for the pure docs-command helpers.
-- Run: nvim --headless -l cadence.nvim/spec/doc_spec.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = here:gsub("/spec/.*$", "")
package.path = root .. "/lua/?.lua;" .. package.path

local doc = require("cadence.doc")

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

-- sync notifications --------------------------------------------------------
do
  io.write("sync\n")
  eq("queued level", doc.sync_result({ status = 202 }).level, "info")
  eq("queued message", doc.sync_result({ status = 202 }).message, "docs queued")

  local skipped = doc.sync_result({ status = 200, body = { status = "skipped", reason = "no_schema" } })
  eq("skipped level", skipped.level, "warn")
  eq("skipped message", skipped.message, "docs skipped: no_schema")

  eq(
    "unconfigured",
    doc.sync_result({ status = 503, body = { error = "doc agent is not configured" } }).message,
    "doc agent is not configured"
  )

  eq(
    "not found",
    doc.sync_result({ status = 404, body = { error = "node not found" } }).message,
    "node not found"
  )

  local unreachable = doc.sync_result({ status = 0, error = "connection refused" })
  eq("unreachable level", unreachable.level, "error")
  eq("unreachable message", unreachable.message, "connection refused")

  eq("fallback message", doc.sync_result({ status = 500 }).message, "docs sync failed")
end

-- diff result mapping -------------------------------------------------------
do
  io.write("diff result\n")
  local payload = { files = {} }
  local ok = doc.diff_result({ status = 200, body = payload })
  eq("payload kind", ok.kind, "diff")
  eq("payload identity", ok.payload, payload)

  local empty = doc.diff_result({ status = 409, body = { error = "no docs commit for this node" } })
  eq("empty kind", empty.kind, "empty")
  eq("empty message", empty.message, "no docs commit for this node")

  local failed = doc.diff_result({ status = 0, error = "unreachable" })
  eq("error kind", failed.kind, "error")
  eq("error message", failed.message, "unreachable")

  eq("default error", doc.diff_result({ status = 500 }).message, "docs diff failed")
end

-- formatting ----------------------------------------------------------------
do
  io.write("format\n")
  local res = doc.format({
    code_commit_sha = "aaaaaaaa11111111",
    docs_commit_sha = "bbbbbbbb22222222",
    files = {
      {
        path = "README.md",
        status = "modified",
        binary = false,
        truncated = false,
        lines = { { kind = "add", text = "new" } },
      },
    },
  })

  eq("header", res.lines[1], "docs aaaaaaaa → bbbbbbbb")
  eq("blank", res.lines[2], "")
  eq("file header", res.lines[3], "README.md  (modified)")
  eq("file header hl", res.hl[3], "CadenceDiffHeader")
  eq("body line", res.lines[4], "+ new")
  eq("body hl", res.hl[4], "CadenceDiffAdd")

  local bare = doc.format({ files = {} })
  eq("no code sha", bare.lines[1], "docs (none) → (none)")
  eq("empty body", bare.lines[3], "(no changes)")
end

io.write("\n")
if failures > 0 then
  io.write(failures, " failure(s)\n")
  os.exit(1)
end
io.write("all doc tests passed\n")
os.exit(0)
