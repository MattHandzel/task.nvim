-- taskwarrior/repair_tags.lua — one-time tag repair.
--
-- Deliberately NOT a :Tw* command: you run this once, ever, and a permanent
-- command slot would clutter the list for every user. Invoke it directly:
--   :lua require("taskwarrior.repair_tags").run()
--   :lua require("taskwarrior.repair_tags").run("status:completed")
--
-- Repairs the damage left by the hyphenated-tag bug: Taskwarrior 3 parses
-- the hyphen in a bare `+foo-bar` token as a subtraction operator, so
-- `task add "… +taco-tuesday"` silently filed the literal text
-- "+taco-tuesday" into the DESCRIPTION instead of creating a tag. Tasks
-- added that way are unfindable by `+taco-tuesday` because the tag never
-- existed. (The same happened via the plugin's literal-add fallback for
-- non-hyphenated tags.)
--
-- This moves those tokens back where they belong: strip `+token` from the
-- description, add `token` to the task's tags.
--
-- It NEVER writes without showing you every proposed change first. Two
-- deliberate conservatisms, because a description legitimately may contain
-- a `+`:
--   * a `+token` wrapped in quotes is skipped — that is someone *writing
--     about* a tag ("searching for \"+ais-research-taste\" fails"), not a
--     mis-parsed one;
--   * the default scope is pending tasks. Completed and deleted history is
--     rarely worth rewriting; pass an explicit filter to include it.

local M = {}

local command = require("taskwarrior.command")
local notify = require("taskwarrior.notify")

-- A tag token: `+` then a tag-legal name, at a word boundary. Mirrors the
-- boundary rule the buffer highlighter uses so "housing+food" is not a tag.
local TOKEN = "%+([A-Za-z_][%w_%-]*)"

local function is_quoted(text, start_idx)
  local prev = start_idx > 1 and text:sub(start_idx - 1, start_idx - 1) or ""
  local after_end = text:find("%s", start_idx) or (#text + 1)
  local following = text:sub(after_end - 1, after_end - 1)
  return (prev == '"' or prev == "'" or prev == "`")
      or (following == '"' or following == "'" or following == "`")
end

--- Find the repairs a task needs. Returns nil when it needs none.
--- Exposed for testing.
function M.plan_for(task)
  local desc = task.description or ""
  local existing = {}
  for _, t in ipairs(task.tags or {}) do existing[t] = true end

  local found, spans = {}, {}
  local pos = 1
  while true do
    local s, e, name = desc:find(TOKEN, pos)
    if not s then break end
    local prev = s > 1 and desc:sub(s - 1, s - 1) or ""
    -- Word boundary before the `+`, and not a quoted mention.
    if (prev == "" or not prev:match("[%w_]")) and not is_quoted(desc, s) then
      if not existing[name] and not vim.tbl_contains(found, name) then
        found[#found + 1] = name
      end
      spans[#spans + 1] = { s, e }
    end
    pos = e + 1
  end
  if #found == 0 then return nil end

  -- Rebuild the description without the token spans, right to left so the
  -- earlier indices stay valid.
  local new_desc = desc
  for i = #spans, 1, -1 do
    new_desc = new_desc:sub(1, spans[i][1] - 1) .. new_desc:sub(spans[i][2] + 1)
  end
  new_desc = new_desc:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if new_desc == "" then
    -- The description was nothing but tags — keep the tag text as the
    -- description rather than creating a task with no description at all.
    new_desc = desc
  end

  local tags = { unpack(task.tags or {}) }
  vim.list_extend(tags, found)
  return {
    uuid = task.uuid,
    old_description = desc,
    new_description = new_desc,
    added_tags = found,
    tags = tags,
  }
end

--- Scan `filter` (default pending) and return the list of planned repairs.
function M.scan(filter)
  filter = (filter and filter ~= "") and filter or "status:pending"
  local tasks = require("taskwarrior.taskmd").shell_export(filter)
  if not tasks then return nil end
  local plans = {}
  for _, t in ipairs(tasks) do
    local plan = M.plan_for(t)
    if plan then plans[#plans + 1] = plan end
  end
  return plans
end

local function preview_lines(plans, filter)
  local lines = {
    ("taskwarrior.nvim — tag repair preview (%s)"):format(filter),
    ("%d task(s) would be changed. Nothing has been written yet."):format(#plans),
    "",
  }
  for i, p in ipairs(plans) do
    lines[#lines + 1] = ("%d. %s"):format(i, p.uuid:sub(1, 8))
    lines[#lines + 1] = ("   tags   + %s"):format(table.concat(p.added_tags, ", "))
    lines[#lines + 1] = ("   before   %s"):format(p.old_description)
    lines[#lines + 1] = ("   after    %s"):format(p.new_description)
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "Quoted mentions (\"+tag\") are deliberately left alone."
  return lines
end

local function apply(plans)
  local taskmd = require("taskwarrior.taskmd")
  local ok_count, failures = 0, {}
  for _, p in ipairs(plans) do
    local ok, out = taskmd.tw_modify(p.uuid, {
      description = p.new_description,
      tags = p.tags,
    })
    if ok then
      ok_count = ok_count + 1
    else
      failures[#failures + 1] = ("%s: %s"):format(p.uuid:sub(1, 8), out or "")
    end
  end
  return ok_count, failures
end

--- Preview, confirm, then repair. `filter` defaults to pending tasks.
function M.run(filter)
  filter = (filter and filter ~= "") and filter or "status:pending"
  local plans = M.scan(filter)
  if not plans then
    notify("error", "taskwarrior.nvim: repair scan failed", vim.log.levels.ERROR)
    return
  end
  if #plans == 0 then
    notify("view", ("taskwarrior.nvim: no tags to repair in `%s`"):format(filter))
    return
  end

  -- Show every change in a scratch buffer before asking. The picker prompt
  -- alone can't carry this much detail, and this is a destructive rewrite of
  -- data the user did not ask us to touch.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, preview_lines(plans, filter))
  vim.bo[buf].modifiable = false
  vim.cmd("tab split")
  vim.api.nvim_win_set_buf(0, buf)
  local preview_win = vim.api.nvim_get_current_win()

  vim.schedule(function()
    vim.ui.select({ "Apply repairs", "Cancel" }, {
      prompt = ("Repair %d task(s)?"):format(#plans),
    }, function(choice)
      if vim.api.nvim_win_is_valid(preview_win) then
        pcall(vim.api.nvim_win_close, preview_win, true)
      end
      if choice ~= "Apply repairs" then
        notify("view", "taskwarrior.nvim: repair cancelled — nothing written")
        return
      end
      local ok_count, failures = apply(plans)
      local msg = ("taskwarrior.nvim: repaired %d/%d task(s)"):format(ok_count, #plans)
      if #failures > 0 then
        notify("error", msg .. "\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
      else
        notify("view", msg .. " — :TwUndo reverts one at a time")
      end
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) and vim.b[b].task_filter ~= nil then
          pcall(function() require("taskwarrior.buffer").refresh_buf(b) end)
        end
      end
    end)
  end)
end

return M
