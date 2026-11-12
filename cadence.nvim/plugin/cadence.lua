local cadence = require("cadence")
local client = require("cadence.client")
local doc = require("cadence.doc")
local graph = require("cadence.graph")
local proposal = require("cadence.proposal")
local ui = require("cadence.ui")

local LEVELS = {
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

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

--- Render a docs diff payload in a scratch split (spec §9.4).
local function open_doc_diff(project, payload, formatted)
  ui.setup_highlights()

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "cadence-doc"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, formatted.lines)
  vim.bo[buf].modifiable = false

  local ns = vim.api.nvim_create_namespace("cadence_doc_diff")
  for i, group in pairs(formatted.hl) do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
      end_row = i,
      end_col = 0,
      hl_group = group,
      hl_eol = true,
    })
  end

  local docs_sha = payload and payload.docs_commit_sha
  local label = docs_sha and docs_sha:sub(1, 8) or project.slug
  -- The same docs commit can be open already; a duplicate name is harmless.
  pcall(vim.api.nvim_buf_set_name, buf, "cadence-docs://" .. label)

  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = false

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end, { buffer = buf })
end

local function notify_result(result)
  vim.notify(result.message, LEVELS[result.level] or vim.log.levels.INFO)
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

vim.api.nvim_create_user_command("CadDocSync", function(args)
  with_project(function(project)
    local node_id = vim.trim(args.args or "")
    local body = { project_id = project.id }

    if node_id ~= "" then
      body.node_id = node_id
    end

    -- The daemon answers immediately (queued/skipped); the generation runs in
    -- the background, so the editor is never blocked on the model.
    client.post_async("/docs/sync", body, socket(), function(res)
      notify_result(doc.sync_result(res))
    end)
  end)
end, { nargs = "?" })

vim.api.nvim_create_user_command("CadDocDiff", function(args)
  with_project(function(project)
    local node_id = vim.trim(args.args or "")
    local path = "/docs/diff?project_id=" .. project.id

    if node_id ~= "" then
      path = path .. "&node_id=" .. node_id
    end

    local result = doc.diff_result(client.get(path, socket()))

    if result.kind == "diff" then
      open_doc_diff(project, result.payload, doc.format(result.payload))
    elseif result.kind == "empty" then
      vim.notify(result.message, vim.log.levels.WARN)
    else
      vim.notify(result.message, vim.log.levels.ERROR)
    end
  end)
end, { nargs = "?" })

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

vim.api.nvim_create_user_command("CadProposals", function()
  with_project(function(project)
    local res = client.get("/proposals?project_id=" .. project.id, socket())
    if not res or res.status ~= 200 or type(res.body) ~= "table" then
      vim.notify("failed to load proposals", vim.log.levels.ERROR)
      return
    end

    local proposals = res.body.proposals or {}
    if #proposals == 0 then
      vim.notify("no union proposals yet; use :CadUnion", vim.log.levels.INFO)
      return
    end

    vim.ui.select(proposals, {
      prompt = "Cadence proposals",
      format_item = function(item)
        return proposal.format_item(item)
      end,
    }, function(choice)
      if not choice then
        return
      end

      local target = proposal.target(choice)
      local result = proposal.copy_result(target)

      if not target.value or target.value == "" then
        vim.notify(result.message, LEVELS[result.level] or vim.log.levels.WARN)
        return
      end

      -- `+` needs a clipboard provider; fall back to the unnamed register.
      if not pcall(vim.fn.setreg, "+", target.value) then
        pcall(vim.fn.setreg, '"', target.value)
      end

      vim.notify(result.message, LEVELS[result.level] or vim.log.levels.INFO)
    end)
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

    -- A daemon that is down is a normal state; never let it break startup.
    local ok, project = pcall(current_project)
    if ok and project then
      vim.schedule(function()
        open_picker(project, { title = project.slug })
      end)
    end
  end,
})
