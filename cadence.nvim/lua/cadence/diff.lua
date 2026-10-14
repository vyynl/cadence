-- Pure formatting of a node diff (`GET /diff` payload) into panel lines.
-- No `vim.*`, so it is unit-testable headlessly (see spec/diff_spec.lua).

local M = {}

local KIND_PREFIX = { add = "+", del = "-", ctx = " " }

local KIND_HL = {
  add = "CadenceDiffAdd",
  del = "CadenceDiffDelete",
  skip = "CadenceDiffMeta",
}

--- Format a diff payload into `{ lines, hl }` where `hl[i]` is the highlight
--- group for 1-based line `i` (nil = default). A nil/empty payload renders a
--- single "(no changes)" line.
function M.format(payload)
  local lines, hl = {}, {}

  local function push(text, group)
    lines[#lines + 1] = text
    if group then
      hl[#lines] = group
    end
  end

  local files = (payload and payload.files) or {}

  if #files == 0 then
    push("(no changes)", "CadenceDiffMeta")
    return { lines = lines, hl = hl }
  end

  for _, file in ipairs(files) do
    push(string.format("%s  (%s)", file.path or "?", file.status or "?"), "CadenceDiffHeader")

    if file.binary then
      push("  (binary file)", "CadenceDiffMeta")
    else
      for _, line in ipairs(file.lines or {}) do
        if line.kind == "skip" then
          push("  …", "CadenceDiffMeta")
        else
          local prefix = KIND_PREFIX[line.kind] or " "
          push(prefix .. " " .. (line.text or ""), KIND_HL[line.kind])
        end
      end
    end

    if file.truncated then
      push("  … (truncated)", "CadenceDiffMeta")
    end
  end

  if payload and payload.truncated then
    push("… more files omitted", "CadenceDiffMeta")
  end

  return { lines = lines, hl = hl }
end

return M
