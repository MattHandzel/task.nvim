-- repair_tags_e2e_spec.lua — :TwRepairTags against a live Taskwarrior CLI.
--
-- Seeds the exact damage the hyphenated-tag bug produced (tag text stuck in
-- the description, tag never created), runs the repair, and asserts the task
-- becomes findable by the tag afterwards. Also asserts the two refusals that
-- keep this safe: a quoted mention is untouched, and Cancel writes nothing.

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local taskmd = require("taskwarrior.taskmd")
local repair = require("taskwarrior.repair_tags")

-- Seed a task the way the bug did: the +tag lives in the description text
-- and no tag exists. `add --` forces a literal description.
local function seed_damaged(description)
  local out = vim.fn.system({
    "task", "rc.bulk=0", "rc.confirmation=off", "rc.verbose=new-uuid",
    "add", "--", description,
  })
  return out:match("[0-9a-fA-F%-]+%-[0-9a-fA-F%-]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+")
end

describe("e2e :TwRepairTags", function()
  if not next(require("taskwarrior.config").options) then
    require("taskwarrior").setup({})
  end

  it("makes a damaged task findable by its tag again", function()
    local tag = ("repair-me-%d"):format(math.random(1, 1e9))
    local uuid = seed_damaged("buy groceries +" .. tag)
    assert.is_truthy(uuid, "seed failed")

    -- Precondition: this is exactly the reported symptom.
    local before = taskmd.shell_export("+" .. tag) or {}
    assert.are.same(0, #before, "seed did not reproduce the bug")
    local seeded = taskmd.shell_export("uuid:" .. uuid)[1]
    assert.are.same("buy groceries +" .. tag, seeded.description)

    local orig_select = vim.ui.select
    vim.ui.select = function(_, _, cb) cb("Apply repairs") end
    repair.run("uuid:" .. uuid)
    vim.wait(5000, function()
      local t = taskmd.shell_export("uuid:" .. uuid)[1]
      return t and t.tags and vim.tbl_contains(t.tags, tag)
    end, 20)
    vim.ui.select = orig_select

    local after = taskmd.shell_export("+" .. tag) or {}
    assert.are.same(1, #after, "task is still not findable by its tag")
    assert.are.same(uuid, after[1].uuid)
    assert.are.same("buy groceries", after[1].description,
      "tag text was not stripped from the description")
  end)

  it("leaves a quoted mention alone", function()
    local tag = ("quoted-%d"):format(math.random(1, 1e9))
    local uuid = seed_damaged(('filtering by "+%s" fails'):format(tag))
    local plans = repair.scan("uuid:" .. uuid)
    assert.are.same({}, plans,
      "a quoted tag mention must not be planned for repair")
  end)

  it("Cancel writes nothing", function()
    local tag = ("cancel-me-%d"):format(math.random(1, 1e9))
    local uuid = seed_damaged("do not touch +" .. tag)

    local orig_select = vim.ui.select
    vim.ui.select = function(_, _, cb) cb("Cancel") end
    repair.run("uuid:" .. uuid)
    vim.wait(1000, function() return false end, 20)
    vim.ui.select = orig_select

    local t = taskmd.shell_export("uuid:" .. uuid)[1]
    assert.are.same("do not touch +" .. tag, t.description,
      "Cancel must not modify the description")
    assert.are.same(0, #(t.tags or {}), "Cancel must not add tags")
  end)

  it("preserves tags the task already had", function()
    local keep = ("kept-%d"):format(math.random(1, 1e9))
    local add = ("added-%d"):format(math.random(1, 1e9))
    local uuid = seed_damaged("mixed tags +" .. add)
    -- Give it a real tag through the (now correct) plugin path.
    assert.is_true(taskmd.tw_change_tag(uuid, keep))

    local orig_select = vim.ui.select
    vim.ui.select = function(_, _, cb) cb("Apply repairs") end
    repair.run("uuid:" .. uuid)
    vim.wait(5000, function()
      local t = taskmd.shell_export("uuid:" .. uuid)[1]
      return t and t.tags and #t.tags == 2
    end, 20)
    vim.ui.select = orig_select

    local t = taskmd.shell_export("uuid:" .. uuid)[1]
    local tags = { unpack(t.tags or {}) }
    table.sort(tags)
    local expected = { keep, add }
    table.sort(expected)
    assert.are.same(expected, tags, "existing tag was lost during repair")
  end)
end)
