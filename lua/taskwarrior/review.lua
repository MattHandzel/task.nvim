local M = {}
local command = require("taskwarrior.command")

-- run_review: walk through pending tasks one by one.
-- open_fn: callback(filter_str) to open a task buffer (M.open from init)
function M.run(open_fn)
  local tasks = require("taskwarrior.taskmd").shell_export("status:pending")
  if not tasks then
    vim.notify("taskwarrior.nvim: failed to export tasks", vim.log.levels.ERROR)
    return
  end
  if #tasks == 0 then
    vim.notify("taskwarrior.nvim: no pending tasks", vim.log.levels.INFO)
    return
  end
  -- Sort by urgency desc for review order
  table.sort(tasks, function(a, b) return (a.urgency or 0) > (b.urgency or 0) end)

  local idx = 1
  local function step()
    if idx > #tasks then
      vim.notify(string.format("taskwarrior.nvim: review complete (%d tasks)", #tasks))
      return
    end
    local t = tasks[idx]
    local short = t.uuid and t.uuid:sub(1, 8) or ""
    -- Show full per-task detail via vim.notify so the picker prompt
    -- stays single-line. Most picker UIs truncate the prompt at the
    -- window width and a multi-line header would be cut off.
    local detail_lines = {
      string.format("[%d/%d]  %s", idx, #tasks, t.description or ""),
      string.format("project:%s  urgency:%.1f", t.project or "(none)", t.urgency or 0),
    }
    if t.due then table.insert(detail_lines, string.format("due:%s", t.due)) end
    if t.tags and #t.tags > 0 then table.insert(detail_lines, "tags:" .. table.concat(t.tags, ",")) end
    vim.notify(table.concat(detail_lines, "\n"), vim.log.levels.INFO)

    local choices = {
      "k  Keep (next)",
      "d  Defer (set wait:tomorrow)",
      "x  Done",
      "m  Modify (prompt)",
      "g  Go to task buffer",
      "q  Quit review",
    }
    vim.ui.select(choices, {
      prompt = string.format("Review %d/%d:", idx, #tasks),
      format_item = function(i) return i end,
    }, function(choice)
      if not choice then return end
      local key = choice:sub(1, 1)
      if key == "k" then
        idx = idx + 1; step()
      elseif key == "d" then
        local result = command.mutate({ short, "modify", "wait:tomorrow" })
        if not result.ok then
          vim.notify("taskwarrior.nvim: defer failed\n" .. result.output, vim.log.levels.ERROR)
          return vim.schedule(step)
        end
        idx = idx + 1; step()
      elseif key == "x" then
        local result = command.mutate({ short, "done" })
        if not result.ok then
          vim.notify("taskwarrior.nvim: done failed\n" .. result.output, vim.log.levels.ERROR)
          return vim.schedule(step)
        end
        idx = idx + 1; step()
      elseif key == "m" then
        vim.ui.input({ prompt = "Modify " .. short .. ": " }, function(input)
          if not input or input == "" then return vim.schedule(step) end
          local parts, err = command.parse_args(input)
          if not parts then
            vim.notify("taskwarrior.nvim: invalid modify arguments\n" .. err,
              vim.log.levels.ERROR)
            return vim.schedule(step)
          end
          local args = { short, "modify" }
          vim.list_extend(args, parts)
          local result = command.mutate(args)
          if not result.ok then
            vim.notify("taskwarrior.nvim: modify failed\n" .. result.output, vim.log.levels.ERROR)
            return vim.schedule(step)
          end
          idx = idx + 1; step()
        end)
      elseif key == "g" then
        open_fn("uuid:" .. short)
      elseif key == "q" then
        vim.notify(string.format("taskwarrior.nvim: review paused at %d/%d", idx, #tasks))
      end
    end)
  end
  step()
end

return M
