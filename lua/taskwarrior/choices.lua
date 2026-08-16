-- taskwarrior/choices.lua — the finite option sets, in one place.
--
-- Sort specs and group fields were previously spelled out three times each
-- (command completion, input() completion, and now the pickers), which is
-- how they drift. Everything that offers these choices reads them here.
--
-- Each entry is { value, label } — `value` is what Taskwarrior/the buffer
-- variable wants, `label` is what a human should see in a picker.

local M = {}

M.SORTS = {
  { value = "urgency-",    label = "urgency ↓  (most urgent first)" },
  { value = "urgency+",    label = "urgency ↑  (least urgent first)" },
  { value = "due+",        label = "due ↑      (soonest first)" },
  { value = "due-",        label = "due ↓      (latest first)" },
  { value = "priority-",   label = "priority ↓ (H → L)" },
  { value = "priority+",   label = "priority ↑ (L → H)" },
  { value = "project+",    label = "project A→Z" },
  { value = "project-",    label = "project Z→A" },
  { value = "description+", label = "description A→Z" },
}

M.GROUPS = {
  { value = "none",     label = "none      (flat list)" },
  { value = "project",  label = "project" },
  { value = "priority", label = "priority" },
  { value = "status",   label = "status" },
  { value = "tag",      label = "tag" },
}

-- Plain value lists, for cmdline completion.
local function values(set)
  local out = {}
  for _, entry in ipairs(set) do out[#out + 1] = entry.value end
  return out
end

function M.sort_values()  return values(M.SORTS)  end
function M.group_values() return values(M.GROUPS) end

--- Filter a value list by a completion prefix.
function M.complete(set, arg_lead)
  arg_lead = arg_lead or ""
  local out = {}
  for _, v in ipairs(values(set)) do
    if v:sub(1, #arg_lead) == arg_lead then out[#out + 1] = v end
  end
  return out
end

return M
