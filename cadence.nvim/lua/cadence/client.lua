local curl = require("plenary.curl")

local M = {}

local function decode(body)
  if body == nil or body == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, body)
  if ok then
    return decoded
  end

  return body
end

--- Perform an HTTP request over the daemon Unix socket.
--- Returns `{ status = number, body = table|string|nil }`, or
--- `{ status = 0, body = nil, error = string }` when the daemon is unreachable.
M.request = function(method, path, body, socket_path)
  local opts = {
    url = "http://localhost" .. path,
    method = method,
    headers = { ["content-type"] = "application/json" },
    raw = { "--unix-socket", socket_path },
  }

  if body then
    opts.body = vim.json.encode(body)
  end

  local ok, res = pcall(curl.request, opts)
  if not ok then
    return { status = 0, body = nil, error = tostring(res) }
  end

  return { status = res.status, body = decode(res.body) }
end

M.get = function(path, socket_path)
  return M.request("GET", path, nil, socket_path)
end

M.post = function(path, body, socket_path)
  return M.request("POST", path, body, socket_path)
end

return M
