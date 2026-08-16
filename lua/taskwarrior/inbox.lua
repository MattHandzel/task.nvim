-- taskwarrior/inbox.lua — :TaskInbox. Triage tasks added in the last N hours
-- that have no project, no due date, and no tags. Walks them one by one,
-- prompting the user to defer, set project, schedule, drop, or skip.
--
-- This is distinct from :TaskReview (which walks all pending tasks by
-- urgency) — :TaskInbox specifically targets "stuff I dumped in and haven't
-- organized yet".

local M = {}
local command = require("taskwarrior.command")

-- Accept hours as a single optional integer (default 24).
function M.run(hours)
  hours = tonumber(hours) or 24
  local cutoff = os.time() - hours * 3600
  -- Taskwarrior's entry.after: expects an ISO-like date. `now-Nh` is simpler.
  local filter = string.format(
    "status:pending entry.after:now-%dh project: -TAGGED", hours)
  local tasks = require("taskwarrior.taskmd").shell_export(filter)
  if not tasks then
    require("taskwarrior.notify")("error",
      "taskwarrior.nvim: failed to fetch inbox", vim.log.levels.ERROR)
    return
  end

  -- Guard: also filter client-side, because TW's `project:` (empty) filter
  -- can be finicky across TW versions.
  local filtered = {}
  for _, t in ipairs(tasks) do
    local has_tags = t.tags and #t.tags > 0
    local has_project = t.project and t.project ~= ""
    local has_due = t.due and t.due ~= ""
    local entry_epoch = 0
    if t.entry then
      local y, mo, d, H, Mi, S = t.entry:match("^(%d%d%d%d)(%d%d)(%d%d)T(%d%d)(%d%d)(%d%d)")
      if y then
        entry_epoch = os.time({
          year = tonumber(y), month = tonumber(mo), day = tonumber(d),
          hour = tonumber(H), min = tonumber(Mi), sec = tonumber(S),
        })
      end
    end
    if not has_project and not has_due and not has_tags and entry_epoch >= cutoff then
      table.insert(filtered, t)
    end
  end

  if #filtered == 0 then
    require("taskwarrior.notify")("review",
      string.format("taskwarrior.nvim: inbox empty (last %dh)", hours))
    return
  end

  local idx = 1
  local function walk()
    if idx > #filtered then
      require("taskwarrior.notify")("review",
        "taskwarrior.nvim: inbox processed")
      return
    end
    local t = filtered[idx]
    local short = t.uuid:sub(1, 8)
    local choices = {
      "set project",
      "schedule",
      "tag",
      "defer (wait 1d)",
      "drop",
      "skip",
      "quit",
    }
    vim.ui.select(choices, {
      prompt = string.format("[%d/%d] %s", idx, #filtered, t.description or ""),
    }, function(choice)
      if not choice or choice == "quit" then return end
      if choice == "skip" then
        idx = idx + 1
        return walk()
      end
      local action
      if choice == "drop" then
        action = function(cb)
          local result = command.mutate({ short, "delete" })
          cb(result.ok, result.output)
        end
      elseif choice == "defer (wait 1d)" then
        action = function(cb)
          local result = command.mutate({ short, "modify", "wait:1d" })
          cb(result.ok, result.output)
        end
      elseif choice == "set project" then
        action = function(cb)
          vim.ui.input({ prompt = "Project: " }, function(v)
            if v and v ~= "" then
              local result = command.mutate({ short, "modify", "project:" .. v })
              return cb(result.ok, result.output)
            end
            cb(nil, "")
          end)
        end
      elseif choice == "schedule" then
        action = function(cb)
          vim.ui.input({ prompt = "Due (e.g. tomorrow, eow): " }, function(v)
            if v and v ~= "" then
              local result = command.mutate({ short, "modify", "due:" .. v })
              return cb(result.ok, result.output)
            end
            cb(nil, "")
          end)
        end
      elseif choice == "tag" then
        action = function(cb)
          vim.ui.input({ prompt = "Tag (no +): " }, function(v)
            if v and v ~= "" then
              -- `modify +v` breaks on hyphenated tags (TW3 parses the hyphen
              -- as subtraction) — use the merge-and-replace helper instead.
              local ok, out = require("taskwarrior.taskmd").tw_change_tag(
                short, (v:gsub("^%+", "")))
              return cb(ok, out)
            end
            cb(nil, "")
          end)
        end
      end
      action(function(ok, out)
        if ok == nil then return vim.schedule(walk) end
        if not ok then
          require("taskwarrior.notify")("error",
            "taskwarrior.nvim: inbox action failed\n" .. (out or ""),
            vim.log.levels.ERROR)
          return vim.schedule(walk)
        end
        idx = idx + 1
        vim.schedule(walk)
      end)
    end)
  end
  walk()
end

return M
