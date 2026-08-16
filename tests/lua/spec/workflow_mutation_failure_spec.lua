-- Interactive workflows must not advance or report success when Taskwarrior
-- rejects the command they issued.

local taskmd = require("taskwarrior.taskmd")

local UUID = "12345678-1234-1234-1234-123456789abc"

local function force_system_failure(message)
  local original = vim.fn.system
  vim.fn.system = function(_)
    original("false") -- update v:shell_error; it is read-only from Lua
    return message or "Taskwarrior rejected the command"
  end
  return original
end

describe("interactive mutation failures", function()
  local original_export
  local original_system
  local original_select
  local original_input
  local original_notify
  local original_notify_module

  before_each(function()
    original_export = taskmd.shell_export
    original_system = vim.fn.system
    original_select = vim.ui.select
    original_input = vim.ui.input
    original_notify = vim.notify
    original_notify_module = package.loaded["taskwarrior.notify"]
  end)

  after_each(function()
    taskmd.shell_export = original_export
    vim.fn.system = original_system
    vim.ui.select = original_select
    vim.ui.input = original_input
    vim.notify = original_notify
    package.loaded["taskwarrior.notify"] = original_notify_module
    package.loaded["taskwarrior.inbox"] = nil
    package.loaded["taskwarrior.review"] = nil
    package.loaded["taskwarrior.granulation"] = nil
  end)

  it("keeps the same inbox item open after a failed action", function()
    taskmd.shell_export = function()
      return {
        {
          uuid = UUID,
          description = "triage me",
          entry = os.date("%Y%m%dT%H%M%SZ"),
        },
      }
    end
    original_system = force_system_failure("delete denied")

    local prompts = {}
    vim.ui.select = function(_, opts, callback)
      prompts[#prompts + 1] = opts.prompt
      callback(#prompts == 1 and "drop" or "quit")
    end
    local notices = {}
    package.loaded["taskwarrior.notify"] = setmetatable({}, {
      __call = function(_, kind, message, level)
        notices[#notices + 1] = { kind = kind, message = message, level = level }
      end,
    })

    require("taskwarrior.inbox").run(24)
    vim.wait(100, function() return #prompts >= 2 end)

    assert.are.equal(2, #prompts)
    assert.is_truthy(prompts[1]:find("[1/1]", 1, true))
    assert.is_truthy(prompts[2]:find("[1/1]", 1, true))
    assert.are.equal("error", notices[1].kind)
    assert.is_truthy(notices[1].message:find("delete denied", 1, true))
  end)

  it("keeps the same review item open after a failed action", function()
    taskmd.shell_export = function()
      return { { uuid = UUID, description = "review me", urgency = 10 } }
    end
    original_system = force_system_failure("done denied")

    local prompts = {}
    vim.ui.select = function(_, opts, callback)
      prompts[#prompts + 1] = opts.prompt
      callback(#prompts == 1 and "x  Done" or "q  Quit review")
    end
    local notices = {}
    vim.notify = function(message, level)
      notices[#notices + 1] = { message = message, level = level }
    end

    require("taskwarrior.review").run(function() end)
    vim.wait(100, function() return #prompts >= 2 end)

    assert.are.same({ "Review 1/1:", "Review 1/1:" }, prompts)
    local saw_error, saw_complete = false, false
    for _, notice in ipairs(notices) do
      saw_error = saw_error or notice.message:find("done denied", 1, true) ~= nil
      saw_complete = saw_complete or notice.message:find("review complete", 1, true) ~= nil
    end
    assert.is_true(saw_error)
    assert.is_false(saw_complete)
  end)

  it("does not claim failed auto-stops succeeded", function()
    taskmd.shell_export = function()
      return { { uuid = UUID, description = "active", start = "20260721T000000Z" } }
    end
    original_system = force_system_failure("stop denied")

    local notices = {}
    package.loaded["taskwarrior.notify"] = setmetatable({}, {
      __call = function(_, kind, message, level)
        notices[#notices + 1] = { kind = kind, message = message, level = level }
      end,
    })

    require("taskwarrior.granulation").stop_all_now()

    assert.are.equal(1, #notices)
    assert.are.equal("error", notices[1].kind)
    assert.is_truthy(notices[1].message:find("failed to auto-stop 1 task", 1, true))
  end)

  it("retains undo work after Taskwarrior rejects an undo", function()
    local apply = require("taskwarrior.apply")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.b[bufnr].task_last_action_count = 2
    vim.ui.select = function(_, _, callback) callback("Undo") end
    original_system = force_system_failure("undo denied")
    local notices = {}
    vim.notify = function(message, level)
      notices[#notices + 1] = { message = message, level = level }
    end
    local refreshed = false

    apply.undo(bufnr, function() refreshed = true end)

    assert.are.equal(2, vim.b[bufnr].task_last_action_count)
    assert.is_false(refreshed)
    assert.are.equal(vim.log.levels.ERROR, notices[1].level)
    assert.is_truthy(notices[1].message:find("2 still pending", 1, true))
    assert.is_truthy(notices[1].message:find("undo denied", 1, true))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("retains only the unprocessed undo count after partial success", function()
    local apply = require("taskwarrior.apply")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.b[bufnr].task_last_action_count = 3
    vim.ui.select = function(_, _, callback) callback("Undo") end
    local calls = 0
    vim.fn.system = function(_)
      calls = calls + 1
      original_system(calls == 1 and "true" or "false")
      return calls == 1 and "" or "undo denied"
    end
    vim.notify = function() end
    local refreshed = false

    apply.undo(bufnr, function() refreshed = true end)

    assert.are.equal(2, vim.b[bufnr].task_last_action_count)
    assert.is_true(refreshed)
    assert.are.equal(2, calls)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
