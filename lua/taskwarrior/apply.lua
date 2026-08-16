local M = {}
local command = require("taskwarrior.command")

-- Backup the Taskwarrior data directory before applying changes. Best-effort:
-- failures are reported but do not block the apply.
local function backup_taskdata()
  local config = require("taskwarrior.config")
  if not config.options.auto_backup then return end
  local location = command.read({ "_get", "rc.data.location" })
  if not location.ok then return end
  local taskdata = tostring(location.output or ""):gsub("%s+$", "")
  if taskdata == "" or vim.fn.isdirectory(taskdata) ~= 1 then return end
  local data = vim.fn.stdpath("data")
  local dest_root = data .. "/taskwarrior.nvim/backups"
  -- Migrate from pre-rename data dir (task.nvim → taskwarrior.nvim, v1.3.0).
  local old_root = data .. "/task.nvim/backups"
  if vim.fn.isdirectory(old_root) == 1 and vim.fn.isdirectory(dest_root) == 0 then
    vim.fn.mkdir(data .. "/taskwarrior.nvim", "p")
    pcall(vim.loop.fs_rename, old_root, dest_root)
  end
  vim.fn.mkdir(dest_root, "p")
  local stamp = os.date("%Y-%m-%d-%H%M%S")
  local dest = dest_root .. "/" .. stamp
  local copy_ok, copy_err = pcall(vim.fn.system, { "cp", "-a", taskdata, dest })
  copy_ok = copy_ok and vim.v.shell_error == 0
  if not copy_ok then
    vim.notify("taskwarrior.nvim: auto-backup failed (" .. tostring(copy_err) .. ")",
      vim.log.levels.WARN)
    return
  end
  -- Prune: keep the N most recent.
  local keep = tonumber(config.options.auto_backup_keep) or 10
  if keep < 1 then keep = 1 end
  local entries = vim.fn.glob(dest_root .. "/*", true, true)
  table.sort(entries)
  while #entries > keep do
    local oldest = table.remove(entries, 1)
    pcall(vim.fn.delete, oldest, "rf")
  end
end

-- Format a single conflict entry for inclusion in the confirm-prompt preview
-- or non-confirm error message.
local function fmt_conflict(c)
  local desc = c.description
  if desc == nil or desc == "" then desc = c.uuid or c.short_uuid or "?" end
  if c.type == "external_modify" then
    return string.format("! conflict: %q was modified both in the buffer AND externally", desc)
  elseif c.type == "external_delete" then
    return string.format("- info: %q is in the buffer but no longer in Taskwarrior (deleted or filter-moved externally) — buffer line ignored", desc)
  elseif c.type == "external_add" then
    return string.format("+ info: %q was added/changed externally after render — preserved, will appear on next refresh", desc)
  else
    return string.format("! conflict (%s): %s", c.type or "unknown", desc)
  end
end

-- Split conflicts into the BLOCKING set (real merge decisions for the user)
-- and the INFORMATIONAL set (out-of-band adds/deletes that just need to be
-- mentioned, not chosen between). Only `external_modify` is blocking — both
-- sides changed the same task and only the user can pick a winner.
local function partition_conflicts(conflicts)
  local blocking, info = {}, {}
  for _, c in ipairs(conflicts or {}) do
    if c.type == "external_modify" then
      table.insert(blocking, c)
    else
      table.insert(info, c)
    end
  end
  return blocking, info
end

-- Apply helper: drives the Lua backend.
-- Returns (result_table, error_string_or_nil).
local function do_apply(opts)
  -- opts: { content=str, tmpfile=str, dry_run=bool, on_delete=str, force=bool }
  local tm = require("taskwarrior.taskmd")
  local ok, result = pcall(tm.apply, {
    content   = opts.content,
    file      = opts.tmpfile,
    dry_run   = opts.dry_run,
    on_delete = opts.on_delete,
    force     = opts.force,
  })
  if ok and type(result) == "table" then return result, nil end
  return nil, tostring(result)
end

-- on_write: BufWriteCmd handler.
-- refresh_fn: callback(bufnr) to re-render (avoids circular require with init)
-- do_apply_fn: callback(bufnr, tmpfile, on_delete, opts) — used for the confirm path
function M.on_write(bufnr, refresh_fn, do_apply_fn)
  local config = require("taskwarrior.config")

  -- Capture :w! up-front: vim.v.cmdbang is set during the BufWriteCmd and may
  -- be clobbered by any nested Ex command we run before we branch on it.
  local force = vim.v.cmdbang == 1

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmpfile = vim.fn.tempname()
  vim.fn.writefile(lines, tmpfile)

  local on_delete = config.options.on_delete or "done"

  if config.options.confirm then
    local decoded, err = do_apply({
      tmpfile = tmpfile,
      dry_run = true,
      on_delete = on_delete,
      force = force,
    })
    if not decoded then
      vim.notify("taskwarrior.nvim: dry-run failed\n" .. (err or ""), vim.log.levels.ERROR)
      vim.fn.delete(tmpfile)
      return
    end

    local actions = decoded.actions or {}
    local conflicts = decoded.conflicts or {}
    local blocking, info = partition_conflicts(conflicts)
    if #actions == 0 and #blocking == 0 and #info == 0 then
      vim.notify("taskwarrior.nvim: no changes")
      vim.bo[bufnr].modified = false
      vim.fn.delete(tmpfile)
      return
    end

    -- Surface informational conflicts (external add/delete) once, up-front.
    -- They don't require a decision, so they don't appear in the prompt.
    if #info > 0 then
      local info_lines = { string.format("taskwarrior.nvim: %d external change(s) detected since render:", #info) }
      for _, c in ipairs(info) do table.insert(info_lines, "  " .. fmt_conflict(c)) end
      vim.notify(table.concat(info_lines, "\n"))
    end

    local labels = {}
    if #blocking > 0 then
      for _, c in ipairs(blocking) do
        table.insert(labels, fmt_conflict(c))
      end
      if #actions > 0 then table.insert(labels, "") end
    end
    for _, action in ipairs(actions) do
      local desc = action.description or (action.fields and action.fields.description) or ""
      if action.type == "add" then
        table.insert(labels, string.format("+ Add: %q", desc))
      elseif action.type == "modify" then
        local parts = {}
        for k, v in pairs(action.fields or {}) do
          table.insert(parts, string.format("%s -> %s", k, tostring(v)))
        end
        table.insert(labels, string.format("~ Modify: %q (%s)", desc, table.concat(parts, ", ")))
      elseif action.type == "done" then
        table.insert(labels, string.format("v Done: %q", desc))
      elseif action.type == "delete" then
        table.insert(labels, string.format("x Delete: %q", desc))
      elseif action.type == "start" then
        table.insert(labels, string.format("> Start: %q", desc))
      elseif action.type == "stop" then
        table.insert(labels, string.format("o Stop: %q", desc))
      else
        table.insert(labels, string.format("? %s: %q", action.type, desc))
      end
    end

    if #actions == 0 and #blocking == 0 then
      -- Only informational conflicts — apply (no actions to run, but refreshes
      -- the buffer to pick up the externally-added/removed tasks).
      do_apply_fn(bufnr, tmpfile, on_delete, { force = false })
      return
    end

    -- Show the per-action preview via vim.notify BEFORE the picker.
    -- Many pickers (telescope, fzf-lua, snacks.nvim, …) render the
    -- prompt as a single-line title bar and truncate at window width,
    -- so a multi-line preview embedded in the prompt gets cut off
    -- ("Apply 3 change(s)? ~ Modify: \"Buy m…" with the rest invisible).
    -- Notifying first puts the full preview in the messages log; the
    -- picker prompt itself stays a short, single-line question.
    vim.notify(table.concat(labels, "\n"), vim.log.levels.INFO)

    local choices, prompt
    if #blocking > 0 then
      choices = {
        "Apply safe (skip conflicts)",
        "Apply force (overwrite external changes)",
        "Cancel",
      }
      prompt = string.format("Apply %d change(s) with %d conflict(s)?", #actions, #blocking)
    else
      choices = { "Apply", "Cancel" }
      prompt = string.format("Apply %d change(s)?", #actions)
    end

    -- Deferred via vim.schedule: on_write runs inside the BufWriteCmd
    -- handler, and float-based vim.ui.select backends (dressing, snacks,
    -- telescope, …) opened from an autocmd context can't take focus — the
    -- picker renders but the cursor stays in the task buffer (issue #3).
    vim.schedule(function()
      vim.ui.select(choices, { prompt = prompt }, function(choice)
        if not choice or choice == "Cancel" then
          vim.notify("taskwarrior.nvim: cancelled")
          vim.fn.delete(tmpfile)
          return
        end
        local apply_force = choice == "Apply force (overwrite external changes)"
        do_apply_fn(bufnr, tmpfile, on_delete, { force = apply_force })
      end)
    end)
  else
    if not force then
      -- Non-confirm mode: dry-run first. Only BLOCKING conflicts (real merge
      -- decisions on the same task) abort the write — informational external
      -- adds/deletes are surfaced and the save proceeds.
      local dry, derr = do_apply({
        tmpfile = tmpfile,
        dry_run = true,
        on_delete = on_delete,
        force = false,
      })
      if not dry then
        vim.notify("taskwarrior.nvim: dry-run failed\n" .. (derr or ""), vim.log.levels.ERROR)
        vim.fn.delete(tmpfile)
        return
      end
      local actions = dry.actions or {}
      local blocking, info = partition_conflicts(dry.conflicts or {})
      if #blocking > 0 then
        local lines_out = { "taskwarrior.nvim: refusing to save — merge conflict on:" }
        for _, c in ipairs(blocking) do table.insert(lines_out, "  " .. fmt_conflict(c)) end
        table.insert(lines_out,
          "Reload the buffer (`:TaskRefresh` or `:e`) and re-apply, or use `:w!` to force.")
        local msg = require("taskwarrior.prefix").rebrand(table.concat(lines_out, "\n"))
        vim.notify(msg, vim.log.levels.ERROR)
        vim.fn.delete(tmpfile)
        return
      end
      if #info > 0 then
        local info_lines = { string.format("taskwarrior.nvim: %d external change(s) detected since render:", #info) }
        for _, c in ipairs(info) do table.insert(info_lines, "  " .. fmt_conflict(c)) end
        vim.notify(table.concat(info_lines, "\n"))
      end
      -- Zero local actions ⇒ skip the apply pipeline entirely. A clean :w on
      -- an unchanged buffer feels free of side effects, and even when
      -- informational external changes were surfaced above, there is nothing
      -- for `task modify` to do.
      if #actions == 0 then
        vim.fn.delete(tmpfile)
        vim.bo[bufnr].modified = false
        return
      end
    end
    do_apply_fn(bufnr, tmpfile, on_delete, { force = force })
  end
end

-- undo: walk back the last N taskwarrior actions recorded on bufnr.
-- refresh_fn: callback(bufnr) to re-render after undo completes.
function M.undo(bufnr, refresh_fn)
  local count = vim.b[bufnr].task_last_action_count
  if not count or count == 0 then
    vim.notify("taskwarrior.nvim: nothing to undo")
    return
  end
  vim.ui.select({ "Undo", "Cancel" }, {
    prompt = string.format("Undo %d action(s) from last save?", count),
  }, function(choice)
    if choice ~= "Undo" then return end
    local succeeded = 0
    local failure_output
    for _ = 1, count do
      local result = command.mutate({ "undo" })
      if not result.ok then
        failure_output = result.output
        break
      end
      succeeded = succeeded + 1
    end
    local remaining = count - succeeded
    vim.b[bufnr].task_last_action_count = remaining > 0 and remaining or nil
    if remaining > 0 then
      local msg = string.format(
        "taskwarrior.nvim: undid %d action(s); %d still pending",
        succeeded, remaining)
      if failure_output and failure_output ~= "" then msg = msg .. "\n" .. failure_output end
      vim.notify(msg, vim.log.levels.ERROR)
    else
      vim.notify(string.format("taskwarrior.nvim: undid %d action(s)", count))
    end
    if succeeded > 0 then refresh_fn(bufnr) end
  end)
end

-- do_apply_and_refresh: apply tmpfile and refresh the buffer.
-- refresh_fn: callback(bufnr) to re-render
-- opts: optional { force = bool } — force skips external-change protections.
function M.do_apply_and_refresh(bufnr, tmpfile, on_delete, refresh_fn, opts)
  opts = opts or {}
  backup_taskdata()
  local summary, err = do_apply({
    tmpfile = tmpfile,
    on_delete = on_delete,
    force = opts.force == true,
  })
  vim.fn.delete(tmpfile)
  if not summary then
    vim.notify("taskwarrior.nvim: apply failed\n" .. (err or ""), vim.log.levels.ERROR)
    return
  end
  vim.b[bufnr].task_last_action_count = summary.action_count or 0
  local msg = string.format(
    "Applied: +%d added, ~%d modified, v%d done",
    summary.added or 0,
    summary.modified or 0,
    summary.completed or 0
  )
  if (summary.deleted or 0) > 0 then
    msg = msg .. string.format(", x%d deleted", summary.deleted)
  end
  -- Distinguish blocking conflicts (real merge decisions skipped) from
  -- informational conflicts (external add/delete preserved on the next
  -- refresh). Pre-v1.5 the message lumped them together as "N skipped"
  -- which spooked users into thinking benign external adds had been
  -- discarded (bug #6).
  if not opts.force and summary.conflicts and #summary.conflicts > 0 then
    local blocking, info = partition_conflicts(summary.conflicts)
    if #blocking > 0 then
      msg = msg .. string.format(" (%d conflict(s) skipped)", #blocking)
    end
    if #info > 0 then
      msg = msg .. string.format(" (%d external change(s) preserved)", #info)
    end
  end
  if summary.errors and #summary.errors > 0 then
    msg = msg .. string.format(" (%d errors!)", #summary.errors)
    local first = summary.errors[1] and summary.errors[1].error
    if first and first ~= "" then msg = msg .. "\n" .. first end
    vim.notify(msg, vim.log.levels.ERROR)
  elseif (summary.action_count or 0) > 0 then
    vim.notify(msg)
  end

  refresh_fn(bufnr)
  vim.bo[bufnr].modified = false
end

return M
