local cadence = require("cadence")
local client = require("cadence.client")
local ui = require("cadence.ui")

local function socket()
  return cadence.socket_path()
end

--- Resolve the project registered for the current working directory, matching
--- `cwd` against each project's `work_dir`. Returns `project, nil` or `nil, err`.
local function current_project()
  local cwd = vim.fn.getcwd()

  local res = client.get("/projects", socket())
  if not res or res.status ~= 200 or not res.body then
    return nil, "cadence daemon unreachable"
  end

  for _, project in ipairs(res.body.projects or {}) do
    if project.work_dir == cwd then
      return project, nil
    end
  end

  return nil, "no project registered for " .. cwd
end

local function node_line(node)
  local flags = table.concat(node.flags or {}, ",")
  return string.format("%-8s  %-14s  %s", node.id:sub(1, 8), flags, node.message or "")
end

vim.api.nvim_create_user_command("CadOpen", function()
  local project, err = current_project()
  if not project then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local res = client.get("/nodes?project_id=" .. project.id, socket())
  if not res or res.status ~= 200 then
    vim.notify("failed to list nodes", vim.log.levels.ERROR)
    return
  end

  local nodes = res.body.nodes or {}
  local lines = vim.tbl_map(node_line, nodes)
  ui.open("cadence — " .. project.slug, lines, nil)
end, {})

vim.api.nvim_create_user_command("CadSpawn", function(args)
  local project, err = current_project()
  if not project then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local name = args.args
  if name == "" then
    name = vim.fn.input("spawn name: ")
  end

  local res = client.post("/spawn", { project_id = project.id, name = name }, socket())
  if res and res.status == 201 then
    vim.notify("spawned " .. res.body.node.id:sub(1, 8), vim.log.levels.INFO)
  else
    vim.notify((res and res.body and res.body.error) or "spawn failed", vim.log.levels.ERROR)
  end
end, { nargs = "?" })

vim.api.nvim_create_user_command("CadSwitch", function()
  local project, err = current_project()
  if not project then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local res = client.get("/nodes?project_id=" .. project.id, socket())
  if not res or res.status ~= 200 then
    vim.notify("failed to list nodes", vim.log.levels.ERROR)
    return
  end

  local nodes = res.body.nodes or {}
  local lines = vim.tbl_map(node_line, nodes)

  ui.open("switch — " .. project.slug, lines, function(row)
    local node = nodes[row]
    if node then
      local switch = client.post(
        "/switch",
        { project_id = project.id, node_id = node.id },
        socket()
      )
      if switch and switch.status == 200 then
        vim.notify("switched to " .. node.id:sub(1, 8), vim.log.levels.INFO)
      else
        vim.notify("switch failed", vim.log.levels.ERROR)
      end
    end
  end)
end, {})
