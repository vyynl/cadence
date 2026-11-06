local cadence = require("cadence")
local client = require("cadence.client")
local graph = require("cadence.graph")
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

--- Run `fn(project)` after resolving the project for the cwd, warning if none.
local function with_project(fn)
  local project, err = current_project()
  if not project then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  fn(project)
end

--- Open the DAG picker for `project`. `opts.union` enables union mode and
--- `opts.on_union` submits the selected node ids.
local function open_picker(project, opts)
  opts = opts or {}

  local res = client.get("/graph?project_id=" .. project.id, socket())
  if not res or res.status == 0 then
    vim.notify("cadence daemon unreachable", vim.log.levels.ERROR)
    return
  end
  if res.status == 404 then
    vim.notify("project not found", vim.log.levels.ERROR)
    return
  end
  if res.status ~= 200 or not res.body then
    vim.notify("failed to load graph", vim.log.levels.ERROR)
    return
  end

  local payload = res.body
  local wrap_width = (cadence.config.graph or {}).wrap_width
  local layout = graph.layout(payload.nodes or {}, payload.edges or {}, { max_cols = wrap_width })

  ui.open_graph(layout, {
    title = opts.title or project.slug,
    default_node_id = payload.default_node_id,
    union = opts.union,
    diff_fetcher = function(node_id)
      local diff = client.get("/diff?project_id=" .. project.id .. "&node_id=" .. node_id, socket())
      if diff and diff.status == 200 then
        return diff.body
      end
      return nil
    end,
    on_switch = function(node_id)
      local switch = client.post("/switch", { project_id = project.id, node_id = node_id }, socket())
      if switch and switch.status == 200 then
        vim.notify("switched to " .. node_id:sub(1, 8), vim.log.levels.INFO)
      else
        vim.notify("switch failed", vim.log.levels.ERROR)
      end
    end,
    on_union = opts.on_union,
  })
end

vim.api.nvim_create_user_command("CadOpen", function()
  with_project(function(project)
    open_picker(project, { title = project.slug })
  end)
end, {})

vim.api.nvim_create_user_command("CadSwitch", function()
  with_project(function(project)
    open_picker(project, { title = "switch — " .. project.slug })
  end)
end, {})

vim.api.nvim_create_user_command("CadUnion", function()
  with_project(function(project)
    open_picker(project, {
      title = "union — " .. project.slug,
      union = true,
      on_union = function(node_ids)
        vim.notify("requesting meld…", vim.log.levels.INFO)

        client.post_async(
          "/union",
          { project_id = project.id, parent_node_ids = node_ids },
          socket(),
          function(res)
            if
              res
              and res.status == 201
              and type(res.body) == "table"
              and type(res.body.proposal_token) == "string"
            then
              local target = res.body.proposal_url or res.body.proposal_token
              vim.notify("meld proposal created: " .. target, vim.log.levels.INFO)
            else
              local message = (res and res.body and res.body.error) or "union failed"
              vim.notify(message, vim.log.levels.ERROR)
            end
          end
        )

        -- Close the picker now; the result arrives asynchronously.
        return true
      end,
    })
  end)
end, {})

vim.api.nvim_create_user_command("CadSpawn", function(args)
  with_project(function(project)
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
  end)
end, { nargs = "?" })

-- Auto-open the picker when Neovim starts inside a registered project (spec
-- §6.3). Best-effort: silently skipped if the daemon is unreachable or the
-- project isn't registered. Disable with `setup({ auto_open = false })`.
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    if cadence.config.auto_open == false then
      return
    end

    local project = current_project()
    if project then
      vim.schedule(function()
        open_picker(project, { title = project.slug })
      end)
    end
  end,
})
