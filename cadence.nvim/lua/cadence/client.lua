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

--- Perform an asynchronous POST over the daemon Unix socket.
---
--- `callback` receives `{ status, body, error }` on the main loop. Used by
--- long-running requests (union can wait on the meld model) so the editor is
--- never blocked.
M.post_async = function(path, body, socket_path, callback)
  local opts = {
    url = "http://localhost" .. path,
    method = "POST",
    headers = { ["content-type"] = "application/json" },
    body = vim.json.encode(body),
    raw = { "--unix-socket", socket_path },
    callback = function(res)
      vim.schedule(function()
        callback({ status = res.status, body = decode(res.body) })
      end)
    end,
    on_error = function(err)
      vim.schedule(function()
        callback({ status = 0, body = nil, error = err.message })
      end)
    end,
  }

  local ok, err = pcall(curl.request, opts)
  if not ok then
    vim.schedule(function()
      callback({ status = 0, body = nil, error = tostring(err) })
    end)
  end
end

return M
