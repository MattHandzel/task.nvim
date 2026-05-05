local M = {}

function M.get_tw_completions()
  local tm = require("taskwarrior.taskmd")
  local ok, data = pcall(tm.tw_completions)
  if ok and type(data) == "table" then return data end
  return { projects = {}, tags = {}, fields = {} }
end

function M.complete_filter(arg_lead)
  local completions = M.get_tw_completions()
  local results = {}

  -- Complete field names
  if not arg_lead:find(":") then
    local fields = { "project", "priority", "status", "due", "scheduled",
                     "recur", "wait", "until", "effort", "tag", "description" }
    for _, f in ipairs(fields) do
      if f:sub(1, #arg_lead) == arg_lead then
        table.insert(results, f .. ":")
      end
    end
    -- Also complete +tag
    if arg_lead == "" or arg_lead:sub(1, 1) == "+" then
      local prefix = arg_lead:sub(2)
      for _, t in ipairs(completions.tags or {}) do
        if prefix == "" or t:sub(1, #prefix) == prefix then
          table.insert(results, "+" .. t)
        end
      end
    end
  else
    -- Complete field values
    local field, val_prefix = arg_lead:match("^(%S-):(.*)$")
    if field == "project" then
      for _, p in ipairs(completions.projects or {}) do
        if val_prefix == "" or p:sub(1, #val_prefix) == val_prefix then
          table.insert(results, field .. ":" .. p)
        end
      end
    elseif field == "priority" then
      for _, v in ipairs({ "H", "M", "L" }) do
        if val_prefix == "" or v:sub(1, #val_prefix) == val_prefix then
          table.insert(results, field .. ":" .. v)
        end
      end
    elseif field == "status" then
      for _, v in ipairs({ "pending", "completed", "deleted", "waiting", "recurring" }) do
        if val_prefix == "" or v:sub(1, #val_prefix) == val_prefix then
          table.insert(results, field .. ":" .. v)
        end
      end
    end
  end
  return results
end

return M
