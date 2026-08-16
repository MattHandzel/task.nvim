local M = {}

-- setup: register every :<prefix>* user command on the running nvim.
--   main: the require("taskwarrior") module (so we can forward to M.open, M.filter, …)
--   complete_filter: arg-lead → completion list (kept as a closure in init.lua)
--
-- Command names are configurable via config.options.command_prefix (default
-- "Task"). All commands here are registered with the prefix prepended to
-- their suffix, e.g. setup({ command_prefix = "Tw" }) creates :Tw, :TwFilter,
-- :TwAdd, … See lua/taskwarrior/config.lua + tests/lua/spec/command_prefix_spec.lua.
function M.setup(main, complete_filter)
  local prefix = require("taskwarrior.config").options.command_prefix or "Tw"

  -- Collision detection — emit a single, actionable WARN if our base
  -- command name (e.g. :Tw) is already defined by another plugin (issue
  -- #1: the historical case was Shatur/neovim-tasks's :Task before we
  -- flipped the default to :Tw in v1.4.1). We still proceed with
  -- registration (nvim_create_user_command silently overrides), since
  -- the user may want our command to win — but we tell them how to opt
  -- out via the prefix knob.
  --
  -- Pick a suggested-override example that's GUARANTEED not to be the
  -- current default — otherwise the WARN would suggest "set prefix to
  -- 'Tw'" to a user whose prefix already IS 'Tw' (no-op).
  local example = (prefix == "TaskW") and "TwX" or "TaskW"
  -- Skip the collision check if WE registered the bare command via the
  -- lazy entrypoint in plugin/taskwarrior.lua (which sets the sentinel
  -- below). Without this guard, every default install fires a false-
  -- positive "another plugin already registered :Tw!" WARN against our
  -- own lazy registration that ran ~10ms earlier.
  local existing = vim.api.nvim_get_commands({})
  local collides = existing[prefix] and vim.g._taskwarrior_lazy_owned_command ~= prefix
  if collides then
    vim.notify(
      ("taskwarrior.nvim: collision — :%s is already defined by another plugin. "
        .. "If you want both, override our prefix BEFORE the plugin loads:\n"
        .. "  vim.g.taskwarrior_command_prefix = '%s'   -- or any unique prefix\n"
        .. "or pass command_prefix = '%s' to setup(). See issue #1."):format(prefix, example, example),
      vim.log.levels.WARN
    )
  end

  -- register(suffix, fn, opts) — concatenate prefix + suffix, install.
  -- suffix == "" gives the bare base command (e.g. :Task / :Tw).
  local function register(suffix, fn, opts)
    vim.api.nvim_create_user_command(prefix .. suffix, fn, opts or {})
  end

  register("", function(cmd_opts)
    main.open(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Open Taskwarrior tasks as markdown",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  register("Filter", function(cmd_opts)
    main.filter(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Change task filter",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  register("Refresh", function()
    main.refresh()
  end, { nargs = 0, desc = "Refresh task buffer" })

  register("Undo", function()
    main.undo()
  end, { nargs = 0, desc = "Undo last save" })

  register("Sort", function(cmd_opts)
    main.sort(cmd_opts.args)
  end, {
    nargs = 1,
    desc = "Change task sort order (e.g. due+, urgency-)",
    complete = function(arg_lead)
      local fields = { "urgency-", "urgency+", "due+", "due-", "priority-",
                       "priority+", "project+", "project-", "description+" }
      local results = {}
      for _, f in ipairs(fields) do
        if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
      end
      return results
    end,
  })

  register("Group", function(cmd_opts)
    main.group(cmd_opts.args)
  end, {
    nargs = "?",
    desc = "Change task grouping (e.g. project, tag, none)",
    complete = function(arg_lead)
      local fields = { "project", "priority", "status", "tag", "none" }
      local results = {}
      for _, f in ipairs(fields) do
        if f:sub(1, #arg_lead) == arg_lead then table.insert(results, f) end
      end
      return results
    end,
  })

  register("Add", function()
    main.capture()
  end, { nargs = 0, desc = "Quick-capture a new task" })

  register("Help", function()
    main.help()
  end, { nargs = 0, desc = "Show taskwarrior.nvim help" })

  register("ProjectAdd", function(cmd_opts)
    main.project_add(cmd_opts.args)
  end, { nargs = "?", desc = "Register cwd as a Taskwarrior project" })

  register("ProjectRemove", function()
    main.project_remove()
  end, { nargs = 0, desc = "Unregister cwd as a project" })

  register("ProjectList", function()
    main.project_list()
  end, { nargs = 0, desc = "List registered projects" })

  register("Delegate", function(cmd_opts)
    local sub = cmd_opts.args
    if sub == "copy" or sub == "copy-command" then
      main.delegate_copy(sub)
    else
      main.delegate()
    end
  end, {
    nargs = "?",
    range = true,
    desc = "Delegate task(s) to Claude",
    complete = function() return { "copy", "copy-command" } end,
  })

  register("Start", function()
    main.start_stop("start")
  end, { nargs = 0, desc = "Start the task on the cursor" })

  register("Stop", function()
    main.start_stop("stop")
  end, { nargs = 0, desc = "Stop the task on the cursor" })

  register("Save", function(cmd_opts)
    main.view_save(cmd_opts.args)
  end, { nargs = 1, desc = "Save the current filter+sort+group as a named view" })

  register("Load", function(cmd_opts)
    main.view_load(cmd_opts.args)
  end, {
    nargs = "?",
    desc = "Load a saved view",
    complete = function(arg_lead)
      local names = main.view_list_names() or {}
      local results = {}
      for _, n in ipairs(names) do
        if n:sub(1, #arg_lead) == arg_lead then table.insert(results, n) end
      end
      return results
    end,
  })

  register("Review", function()
    main.review()
  end, { nargs = 0, desc = "Walk through pending tasks one at a time" })

  register("DiffPreview", function(cmd_opts)
    local dp = require("taskwarrior.diff_preview")
    local a = cmd_opts.args
    if a == "on" then dp.enable()
    elseif a == "off" then dp.disable()
    else dp.toggle() end
  end, {
    nargs = "?",
    desc = "Toggle live diff preview (virtual text)",
    complete = function() return { "on", "off", "toggle" } end,
  })

  -- Visualization commands
  local views = require("taskwarrior.views")

  register("Burndown", function()
    views.burndown()
  end, { nargs = 0, desc = "Show burndown chart" })

  register("Tree", function()
    views.tree()
  end, { nargs = 0, desc = "Show dependency tree" })

  register("Summary", function()
    views.summary()
  end, { nargs = 0, desc = "Show project summary" })

  register("Calendar", function()
    views.calendar()
  end, { nargs = 0, desc = "Show calendar view of due dates" })

  register("Tags", function()
    views.tags()
  end, { nargs = 0, desc = "Show tag distribution" })

  -- Repair tasks whose `+tag` text ended up in the description (the
  -- hyphenated-tag misparse). Previews every change before writing.
  register("RepairTags", function(o)
    require("taskwarrior.repair_tags").run(o.args)
  end, {
    nargs = "*",
    desc = "Move +tag text stuck in descriptions back into real tags (previews first)",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  register("Table", function(o)
    require("taskwarrior.table_view").open(o.args)
  end, {
    nargs = "*",
    desc = "Show tasks as a configurable column table",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  -- Structured feedback buffer. Default config: GitHub-issue + clipboard
  -- always available; HTTP "Send" only when feedback_endpoint is set.
  --   :<prefix>Feedback              open the empty form
  --   :<prefix>Feedback last-error   prefill from the most recent ERROR
  register("Feedback", function(o)
    local fb = require("taskwarrior.feedback")
    if o.args == "last-error" then fb.last_error() else fb.open() end
  end, {
    nargs = "?",
    desc = "Open the feedback form (subcommand: last-error)",
    complete = function() return { "last-error" } end,
  })

  -- Task-level ops
  register("Append", function(o)
    main.append(o.args)
  end, { nargs = "*", desc = "Append text to description of task under cursor" })

  register("Prepend", function(o)
    main.prepend(o.args)
  end, { nargs = "*", desc = "Prepend text to description of task under cursor" })

  register("Duplicate", function()
    main.duplicate()
  end, { nargs = 0, desc = "Duplicate the task under cursor" })

  register("Purge", function(o)
    main.purge(o.args)
  end, { nargs = "*", desc = "Irreversibly purge deleted tasks (by filter)" })

  register("Denotate", function()
    main.denotate()
  end, { nargs = 0, desc = "Remove an annotation from the task under cursor" })

  register("ModifyField", function(o)
    main.modify_field_by_name(o.args)
  end, {
    nargs = 1,
    desc = "Modify a single field of the task under cursor via picker",
    complete = function() return { "project", "priority", "due", "tag" } end,
  })

  register("BulkModify", function(o)
    main.bulk_modify({ o.line1, o.line2 }, o.args)
  end, {
    nargs = "+", range = true,
    desc = "Apply the same modify to every task in the selected range",
  })

  -- Named reports (task next / active / overdue / ...)
  register("Report", function(o)
    main.report(o.args)
  end, {
    nargs = "?",
    desc = "Open a named Taskwarrior report",
    complete = function(arg_lead)
      local names = main.report_names() or {}
      local out = {}
      for _, n in ipairs(names) do
        if n:sub(1, #arg_lead) == arg_lead then table.insert(out, n) end
      end
      return out
    end,
  })

  -- Differentiators
  register("Graph", function()
    main.graph()
  end, { nargs = 0, desc = "Render the dependency graph as a Mermaid diagram" })

  register("Inbox", function()
    main.inbox()
  end, { nargs = 0, desc = "Triage recently-added tasks with no project/due/tags" })

  register("Export", function(o)
    main.export(o.args)
  end, { nargs = "?", desc = "Write the rendered task buffer to a markdown file" })

  register("Sync", function()
    main.sync()
  end, { nargs = 0, desc = "Run `task sync` with progress and error handling" })

  -- Taskwarrior contexts (work, home, …).
  --   :TwContext                      clear the active context
  --   :TwContext <name>               activate it
  --   :TwContext show                 active context + the defined ones
  --   :TwContext define [name] [filter]  create one (prompts for anything
  --                                      not supplied)
  --   :TwContext delete [name]        remove a definition (prompts if omitted)
  register("Context", function(o)
    local ctx = require("taskwarrior.context")
    local sub, rest = o.args:match("^(%S+)%s*(.*)$")
    if sub == "define" then
      local name, filter = rest:match("^(%S+)%s*(.*)$")
      ctx.define(name, filter)
    elseif sub == "delete" then
      ctx.delete(rest)
    else
      main.context(o.args)
    end
  end, {
    nargs = "*",
    desc = "Taskwarrior context: bare = clear, <name> = activate, show/define/delete",
    complete = function(arg_lead, cmd_line)
      -- After `define`/`delete`, complete context names rather than verbs.
      local words = vim.split(cmd_line or "", "%s+")
      local sub = words[2]
      local names = require("taskwarrior.context").list()
      local candidates
      if sub == "delete" and #words > 2 then
        candidates = names
      elseif sub == "define" or (sub == "delete" and #words > 3) then
        candidates = {}
      else
        candidates = vim.list_extend({ "none", "show", "define", "delete" }, names)
      end
      local out = {}
      for _, n in ipairs(candidates) do
        if n:sub(1, #arg_lead) == arg_lead then table.insert(out, n) end
      end
      return out
    end,
  })

  register("Float", function(o)
    require("taskwarrior.buffer").open_float(o.args)
  end, {
    nargs = "*",
    desc = "Open tasks in a centered floating window",
    complete = function(arg_lead) return complete_filter(arg_lead) end,
  })

  -- Interactive tutor (sandboxed; never touches real ~/.task)
  register("Tutor", function(o)
    local tutor = require("taskwarrior.tutor")
    if o.args == "reset" then
      tutor.reset()
      vim.notify("taskwarrior.tutor: cleaned up active session and any orphan temp dirs",
        vim.log.levels.INFO)
    else
      tutor.start()
    end
  end, {
    nargs = "?",
    desc = "Open the interactive tutorial (subcommand: reset)",
    complete = function() return { "reset" } end,
  })

  -- Nested checkbox → dependency helpers
  register("LinkChildren", function()
    require("taskwarrior.nested").link_children()
  end, {
    nargs = 0,
    desc = "Mark indented tasks below cursor as depends: of the cursor task",
  })
  register("UnlinkChildren", function()
    require("taskwarrior.nested").unlink_children()
  end, { nargs = 0, desc = "Remove depends: for indented children of cursor task" })
end

return M
