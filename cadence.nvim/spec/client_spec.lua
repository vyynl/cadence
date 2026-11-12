-- Headless unit tests for the daemon client's failure handling.
-- Run: nvim --headless -l cadence.nvim/spec/client_spec.lua

local here = debug.getinfo(1, "S").source:sub(2)
local root = here:gsub("/spec/.*$", "")
package.path = root .. "/lua/?.lua;" .. package.path

-- Replace plenary.curl before the client loads. The real synchronous request
-- raises from a libuv callback when the daemon socket is stale; the client
-- must turn that into `{status = 0, error = ...}`.
local fake_curl = {}
package.loaded["plenary.curl"] = fake_curl

local client = require("cadence.client")

local failures = 0

local function eq(name, actual, expected)
  if actual == expected then
    io.write("  ok   ", name, "\n")
  else
    io.write("  FAIL ", name, " (got " .. tostring(actual) .. ", want " .. tostring(expected) .. ")\n")
    failures = failures + 1
  end
end

do
  io.write("unreachable daemon\n")

  fake_curl.request = function(opts)
    opts.on_error({ message = "curl: (7) Failed to connect" })
    return {}
  end

  local result = client.get("/projects", "/tmp/missing.sock")
  eq("status is zero", result.status, 0)
  eq("body is nil", result.body, nil)
  eq("error is surfaced", result.error, "curl: (7) Failed to connect")
end

do
  io.write("raising request\n")

  fake_curl.request = function(_opts)
    error("boom")
  end

  local result = client.get("/projects", "/tmp/missing.sock")
  eq("status is zero", result.status, 0)
  eq("body is nil", result.body, nil)
  eq("raised error is surfaced", result.error:find("boom", 1, true) ~= nil, true)
end

do
  io.write("successful request\n")

  fake_curl.request = function(_opts)
    return { status = 200, body = '{"projects":[]}' }
  end

  local result = client.get("/projects", "/tmp/missing.sock")
  eq("status is kept", result.status, 200)
  eq("body is decoded", type(result.body), "table")
  eq("projects", #result.body.projects, 0)
end

if failures > 0 then
  io.write("\n", failures, " failure(s)\n")
  vim.cmd("cquit 1")
end

io.write("\nall client tests passed\n")
