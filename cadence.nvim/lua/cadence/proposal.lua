-- Pure helpers for the `:CadProposals` command. No daemon or Neovim state.
-- Run the spec with: nvim --headless -l cadence.nvim/spec/proposal_spec.lua

local M = {}

local KIND_TITLES = {
  meld = "Meld",
  promotion = "Promotion",
  proposal = "Proposal",
}

--- Human title for a proposal kind.
M.kind_title = function(kind)
  if type(kind) == "string" then
    return KIND_TITLES[kind] or "Proposal"
  end
  return "Proposal"
end

--- Relative age from the daemon's `age_seconds` (computed server-side so the
--- Lua side never has to parse an ISO timestamp across timezones).
M.age = function(seconds)
  if type(seconds) ~= "number" or seconds < 0 then
    return "unknown"
  end
  if seconds < 60 then
    return "just now"
  end
  if seconds < 3600 then
    return string.format("%dm", math.floor(seconds / 60))
  end
  if seconds < 86400 then
    return string.format("%dh", math.floor(seconds / 3600))
  end
  return string.format("%dd", math.floor(seconds / 86400))
end

--- One-line label for `vim.ui.select`'s `format_item`.
M.format_item = function(proposal)
  proposal = proposal or {}

  local parents = 0
  if type(proposal.parent_node_ids) == "table" then
    parents = #proposal.parent_node_ids
  end

  local parent_label
  if parents == 1 then
    parent_label = "1 parent"
  else
    parent_label = tostring(parents) .. " parents"
  end

  local token = type(proposal.token) == "string" and proposal.token or ""
  local short = token ~= "" and token:sub(1, 10) or "unknown"

  return table.concat({
    M.kind_title(proposal.kind),
    parent_label,
    M.age(proposal.age_seconds),
    short,
  }, " · ")
end

--- The value to copy: the public URL when known, otherwise the bare token.
M.target = function(proposal)
  proposal = proposal or {}

  if type(proposal.url) == "string" and proposal.url ~= "" then
    return { kind = "url", value = proposal.url }
  end

  if type(proposal.token) == "string" and proposal.token ~= "" then
    return { kind = "token", value = proposal.token }
  end

  return { kind = "none", value = nil }
end

--- Notification for a copy attempt (level is `info` or `warn`).
M.copy_result = function(target)
  if not target or not target.value or target.value == "" then
    return { level = "warn", message = "this proposal has no URL or token" }
  end

  if target.kind == "url" then
    return { level = "info", message = "copied proposal URL: " .. target.value }
  end

  return { level = "warn", message = "server URL not configured; copied token: " .. target.value }
end

return M
