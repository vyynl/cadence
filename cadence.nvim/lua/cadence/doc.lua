-- Pure formatting and result mapping for the documentation commands.
-- No `vim.*`, so it is unit-testable headlessly (see spec/doc_spec.lua).

local M = {}

local function body_table(res)
  if type(res) == "table" and type(res.body) == "table" then
    return res.body
  end
  return nil
end

local function body_error(res, fallback)
  local body = body_table(res)
  if body and type(body.error) == "string" then
    return body.error
  end
  return fallback
end

local function unreachable(res)
  if type(res) == "table" and type(res.error) == "string" then
    return res.error
  end
  return "cadence daemon unreachable"
end

--- Map a `POST /docs/sync` response to `{ level, message }`, where `level` is
--- "info" | "warn" | "error" (the caller maps it to `vim.log.levels`).
function M.sync_result(res)
  if not res or res.status == 0 then
    return { level = "error", message = unreachable(res) }
  end

  if res.status == 202 then
    return { level = "info", message = "docs queued" }
  end

  if res.status == 200 then
    local body = body_table(res) or {}
    local reason = body.reason or "skipped"
    return { level = "warn", message = "docs skipped: " .. tostring(reason) }
  end

  if res.status == 503 then
    return { level = "warn", message = body_error(res, "doc agent is not configured") }
  end

  if res.status == 404 then
    return { level = "warn", message = body_error(res, "project or node not found") }
  end

  return { level = "error", message = body_error(res, "docs sync failed") }
end

--- Map a `GET /docs/diff` response to `{ kind, payload | message }`:
---
---   { kind = "diff", payload = <payload> }
---   { kind = "empty", message = <why there is no docs commit> }
---   { kind = "error", message = <why the request failed> }
function M.diff_result(res)
  if not res or res.status == 0 then
    return { kind = "error", message = unreachable(res) }
  end

  local body = body_table(res)

  if res.status == 200 and body then
    return { kind = "diff", payload = body }
  end

  if res.status == 409 then
    return { kind = "empty", message = body_error(res, "no docs commit for this node") }
  end

  return { kind = "error", message = body_error(res, "docs diff failed") }
end

local function short(sha)
  if type(sha) ~= "string" or sha == "" then
    return "(none)"
  end
  return sha:sub(1, 8)
end

--- Format a docs diff payload using the shared `cadence.diff` formatter, with
--- a header naming the code and docs commits.
function M.format(payload)
  local diff = require("cadence.diff")
  local body = diff.format(payload)

  local lines = {
    string.format(
      "docs %s → %s",
      short(payload and payload.code_commit_sha),
      short(payload and payload.docs_commit_sha)
    ),
    "",
  }
  local hl = { "CadenceDiffHeader" }

  for i, line in ipairs(body.lines) do
    lines[#lines + 1] = line
    hl[#lines] = body.hl[i]
  end

  return { lines = lines, hl = hl }
end

return M
