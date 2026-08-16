-- Regression spec: sorting by a field that only SOME tasks have.
--
-- The comparator used to do `return ma < mb` on two booleans ("is this side
-- missing?"), which Lua rejects with "attempt to compare two boolean
-- values". Any sort on a partially-populated field — priority, due, project
-- — therefore blew up the whole render with a Lua error instead of sorting.
-- Real databases always have such fields, so this hit `:TwSort priority-`
-- almost immediately.

local eq = assert.are.same
local tm = require("taskwarrior.taskmd")

-- Task descriptions in render order. The rendered line carries the fields
-- too (`has high priority:H`), so cut at the first metadata token.
local function descriptions(out)
  local names = {}
  for line in out:gmatch("[^\n]+") do
    local d = line:match("^%- %[.%]%s+(.-)%s*<!%-%-")
    if d then
      d = d:gsub("%s+[%w_]+:%S+", ""):gsub("%s+$", "")
      names[#names + 1] = d
    end
  end
  return names
end

describe("render sorting with a partially-present field", function()
  local TASKS = {
    { uuid = "aaaa1111-0000-0000-0000-000000000001",
      description = "has high", status = "pending", priority = "H", urgency = 5 },
    { uuid = "bbbb2222-0000-0000-0000-000000000002",
      description = "no priority", status = "pending", urgency = 4 },
    { uuid = "cccc3333-0000-0000-0000-000000000003",
      description = "has low", status = "pending", priority = "L", urgency = 3 },
  }

  local orig_export
  before_each(function()
    orig_export = tm.tw_export
    tm.tw_export = function() return vim.deepcopy(TASKS) end
  end)
  after_each(function() tm.tw_export = orig_export end)

  local function render(sort)
    local ok, out = pcall(tm.render, { filter = {}, sort = sort })
    assert.is_true(ok, "render errored for sort " .. sort .. ": " .. tostring(out))
    return descriptions(out)
  end

  it("does not error sorting descending by a missing field", function()
    local names = render("priority-")
    eq(3, #names)
    eq("no priority", names[3], "task without the field should sort last")
  end)

  it("does not error sorting ascending by a missing field", function()
    local names = render("priority+")
    eq(3, #names)
    eq("no priority", names[3],
      "a missing value sorts last in BOTH directions — it is absent, not small")
  end)

  -- Priority is ordinal (H > M > L), not alphabetical. Sorting the letters
  -- put "L" above "H" descending, so `priority-` — which reads as "most
  -- important first", matching `urgency-` — listed the least important
  -- tasks first.
  it("orders priority by importance, not alphabetically", function()
    eq({ "has high", "has low", "no priority" }, render("priority-"))
    eq({ "has low", "has high", "no priority" }, render("priority+"))
  end)

  it("handles every field missing without erroring", function()
    local names = render("project-")
    eq(3, #names)
  end)
end)
