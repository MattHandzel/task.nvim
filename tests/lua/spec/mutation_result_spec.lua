-- Mutation result accounting: Taskwarrior exit status, not the absence of a
-- Lua exception, determines whether an apply action succeeded.

local taskmd = require("taskwarrior.taskmd")

local UUID = "12345678-1234-1234-1234-123456789abc"
local BASE = {
  uuid = UUID,
  status = "pending",
  description = "before",
  entry = "20260101T000000Z",
  modified = "20260101T000000Z",
}

local function apply_line(line)
  return taskmd.apply({ content = line .. "\n", force = true })
end

describe("taskmd.apply mutation result accounting", function()
  local originals

  before_each(function()
    originals = {
      tw_export = taskmd.tw_export,
      tw_add = taskmd.tw_add,
      tw_modify = taskmd.tw_modify,
      tw_done = taskmd.tw_done,
      tw_delete = taskmd.tw_delete,
      tw_start = taskmd.tw_start,
      tw_stop = taskmd.tw_stop,
    }
  end)

  after_each(function()
    for name, fn in pairs(originals) do taskmd[name] = fn end
  end)

  it("does not count a rejected modify as successful", function()
    taskmd.tw_export = function() return { vim.deepcopy(BASE) } end
    taskmd.tw_modify = function()
      return false, "Taskwarrior rejected the field", 12
    end

    local summary = apply_line(
      "- [ ] after <!-- uuid:12345678 -->")

    assert.are.equal(0, summary.modified)
    assert.are.equal(0, summary.action_count)
    assert.are.equal(1, #summary.errors)
    assert.is_truthy(summary.errors[1].error:find("exit 12", 1, true))
    assert.is_truthy(summary.errors[1].error:find("rejected the field", 1, true))
  end)

  it("counts a successful modify and its undoable command", function()
    taskmd.tw_export = function() return { vim.deepcopy(BASE) } end
    taskmd.tw_modify = function() return true, "", 0 end

    local summary = apply_line(
      "- [ ] after <!-- uuid:12345678 -->")

    assert.are.equal(1, summary.modified)
    assert.are.equal(1, summary.action_count)
    assert.are.same({}, summary.errors)
  end)

  it("does not count a rejected add as successful", function()
    taskmd.tw_export = function() return {} end
    taskmd.tw_add = function() return "", false, "invalid due date", 1 end

    local summary = apply_line("- [ ] new task due:not-a-date")

    assert.are.equal(0, summary.added)
    assert.are.equal(0, summary.action_count)
    assert.are.equal(1, #summary.errors)
    assert.is_truthy(summary.errors[1].error:find("invalid due date", 1, true))
  end)

  it("records a successful ambiguous add without retrying it", function()
    taskmd.tw_export = function() return {} end
    local calls = 0
    taskmd.tw_add = function()
      calls = calls + 1
      return "", true, "Created task 1.", 0
    end

    local summary = apply_line("- [ ] new task")

    assert.are.equal(1, calls)
    assert.are.equal(1, summary.added)
    assert.are.equal(1, summary.action_count)
    assert.are.same({}, summary.errors)
  end)

  it("counts add and post-state as separate undoable commands", function()
    taskmd.tw_export = function() return {} end
    taskmd.tw_add = function() return UUID, true, "", 0 end
    taskmd.tw_done = function() return true, "", 0 end

    local summary = apply_line("- [x] completed at creation")

    assert.are.equal(1, summary.added)
    assert.are.equal(1, summary.completed)
    assert.are.equal(2, summary.action_count)
    assert.are.same({}, summary.errors)
  end)
end)
