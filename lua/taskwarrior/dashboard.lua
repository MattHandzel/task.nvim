-- taskwarrior/dashboard.lua — snippet helpers for alpha-nvim / dashboard.nvim.
--
-- Returns a list of strings — the top-N most urgent pending tasks — for use
-- in a startup dashboard section. Intentionally synchronous and cheap:
-- called at vim-open time, should not spawn heavy IO.
--
-- Example (alpha.nvim):
--
--   local tw = require("taskwarrior.dashboard")
--   dashboard.section.buttons.val = {
--     dashboard.button("t", "  Tasks", ":Task<CR>"),
--     -- ...
--   }
--   dashboard.section.footer.val = tw.top_urgent(5)
--
-- Example (dashboard.nvim):
--
--   require("dashboard").setup({
--     custom_section = {
--       tasks = {
--         description = require("taskwarrior.dashboard").top_urgent(5),
--         command = ":Task",
--       },
--     },
--   })

local M = {}

--- Return up to `n` pending tasks as a list of pretty-printed lines
--- (sorted by urgency descending). If no tasks exist, returns a single
--- "No pending tasks" line so dashboards render something meaningful.
function M.top_urgent(n)
  n = n or 5
  local tasks = require("taskwarrior.taskmd").shell_export("status:pending")
  if not tasks or #tasks == 0 then
    return { "No pending tasks" }
  end
  table.sort(tasks, function(a, b) return (a.urgency or 0) > (b.urgency or 0) end)
  local lines = {}
  for i = 1, math.min(n, #tasks) do
    local t = tasks[i]
    local desc = (t.description or ""):gsub("\n", " ")
    local urg = t.urgency and string.format("%5.1f", t.urgency) or "    ."
    local prio = t.priority and (" !" .. t.priority) or ""
    local proj = t.project and (" @" .. t.project) or ""
    table.insert(lines, string.format("  %s  %s%s%s", urg, desc, prio, proj))
  end
  return lines
end

return M
