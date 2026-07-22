-- Live contract tests for taskwarrior.command. The e2e runner sets HOME,
-- TASKRC, and TASKDATA to a throwaway directory before Neovim starts, so
-- these tests never read or write the user's normal Taskwarrior database.

local command = require("taskwarrior.command")
local taskmd = require("taskwarrior.taskmd")

local TMP = assert(os.getenv("TASKWARRIOR_E2E_TMP"),
  "command live spec requires tests/e2e/run.sh isolation")

describe("live centralized command boundary", function()
  it("runs against the isolated Taskwarrior database", function()
    local location = command.read({ "_get", "rc.data.location" })
    assert.is_true(location.ok)
    assert.are.equal(os.getenv("TASKDATA"), vim.trim(location.output))
    assert.is_truthy(vim.trim(location.output):find(TMP, 1, true))
  end)

  it("preserves shell-looking descriptions as literal argv data", function()
    local marker = TMP .. "/command-boundary-must-not-exist"
    local description = "LIVE_ARGV ; touch " .. marker .. " $(uname) 'quoted'"

    local uuid, ok, output, code = taskmd.tw_add(description, { project = "commandtest" })

    assert.is_true(ok, (output or "") .. " (exit " .. tostring(code) .. ")")
    assert.is_not.equal("", uuid)
    assert.are.equal(0, vim.fn.filereadable(marker),
      "shell-looking task text must never execute")
    local tasks = taskmd.shell_export("uuid:" .. uuid)
    assert.are.equal(1, #tasks)
    assert.are.equal(description, tasks[1].description)
  end)

  it("performs a real mutation and observes it through a real export", function()
    local uuid, added = taskmd.tw_add("LIVE_MUTATION before", {})
    assert.is_true(added)

    local result = command.mutate({ uuid, "modify", "description:LIVE_MUTATION after" })
    assert.is_true(result.ok, result.output)

    local tasks = taskmd.shell_export("uuid:" .. uuid)
    assert.are.equal(1, #tasks)
    assert.are.equal("LIVE_MUTATION after", tasks[1].description)
  end)

  it("returns a failed result for a rejected real mutation", function()
    local before = taskmd.shell_export("status:pending")
    local result = command.mutate({ "00000000-0000-0000-0000-000000000000", "done" })
    local after = taskmd.shell_export("status:pending")

    assert.is_false(result.ok)
    assert.is_true(result.code ~= 0)
    assert.are.equal(#before, #after, "rejected mutation must not alter task count")
  end)

  it("returns the same contract from a real asynchronous read", function()
    local result
    local job = command.start({ "status:pending", "count" }, { kind = "read" },
      function(value) result = value end)

    assert.is_truthy(job)
    assert.is_true(vim.wait(3000, function() return result ~= nil end, 10),
      "timed out waiting for Taskwarrior count")
    assert.is_true(result.ok, (result.stderr or "") .. (result.output or ""))
    assert.is_truthy(tonumber(vim.trim(result.output)))
  end)
end)
