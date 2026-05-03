-- tests/lua/spec/degraded_env_spec.lua
--
-- Regression spec for the bug class "plugin crashes when its hard
-- dependencies are missing." The immediate trigger was issue #2: `task`
-- not on PATH → vim.fn.system({"task",...}) raised E475 from inside
-- vim.schedule with no friendly fallback. This bug class was invisible
-- to every other suite because:
--   - CI installs taskwarrior at the top of every job
--   - the e2e harness (tests/e2e/run.sh) requires `task` for its own
--     fixture-seeding step
--   - no spec ever monkey-patched vim.fn.executable to simulate a
--     missing dependency
--
-- This spec covers the methodology gap. Asserts:
--   A. plugin/taskwarrior.lua emits one clear WARN at startup when
--      `task` is not on PATH (Layer A — catches the common case where
--      the user installed the plugin without Taskwarrior)
--   B. taskmd.lua's run() short-circuits cleanly when the binary is
--      unavailable, never calling vim.fn.system (Layer B — catches
--      mid-session uninstall and PATH changes)
--   C. notify is emitted at most once per session, not per call

local PLUGIN_FILE = vim.fn.fnamemodify(
  debug.getinfo(1, "S").source:sub(2), ":h:h:h:h"
) .. "/plugin/taskwarrior.lua"

describe("degraded environment — `task` binary missing", function()
  local original = {}
  local notifications

  before_each(function()
    original.executable = vim.fn.executable
    original.system = vim.fn.system
    original.notify = vim.notify
    notifications = {}
    vim.notify = function(msg, level, _opts)
      table.insert(notifications, { msg = tostring(msg or ""), level = level })
    end
  end)

  after_each(function()
    vim.fn.executable = original.executable
    vim.fn.system = original.system
    vim.notify = original.notify
  end)

  local function find_warn(pattern)
    for _, n in ipairs(notifications) do
      if n.level == vim.log.levels.WARN and n.msg:match(pattern) then
        return n
      end
    end
    return nil
  end

  local function force_task_missing()
    local orig = original.executable
    vim.fn.executable = function(cmd)
      if cmd == "task" then return 0 end
      return orig(cmd)
    end
  end

  local function force_task_present()
    local orig = original.executable
    vim.fn.executable = function(cmd)
      if cmd == "task" then return 1 end
      return orig(cmd)
    end
  end

  describe("Layer A: startup-time check (plugin/taskwarrior.lua)", function()
    it("emits a friendly WARN when `task` is not executable at startup", function()
      force_task_missing()
      vim.g.loaded_taskwarrior = nil
      assert(loadfile(PLUGIN_FILE))()
      local hit = find_warn("[Tt]askwarrior")
      assert(hit,
        "expected WARN notify mentioning Taskwarrior; got:\n" .. vim.inspect(notifications))
      assert(
        hit.msg:match("PATH") or hit.msg:match("install") or hit.msg:match("taskwarrior%.org"),
        "WARN should mention PATH / install / taskwarrior.org; got: " .. hit.msg)
    end)

    it("does NOT emit a missing-binary WARN when `task` is present", function()
      force_task_present()
      vim.g.loaded_taskwarrior = nil
      assert(loadfile(PLUGIN_FILE))()
      assert(not find_warn("not found on PATH"),
        "should not warn about missing PATH when task is available; got:\n"
          .. vim.inspect(notifications))
    end)
  end)

  describe("Layer B: runtime defense (lua/taskwarrior/taskmd.lua run())", function()
    it("does not invoke vim.fn.system when `task` is unavailable", function()
      force_task_missing()
      local system_calls = {}
      vim.fn.system = function(argv)
        table.insert(system_calls, argv)
        return ""
      end

      package.loaded["taskwarrior.taskmd"] = nil
      local taskmd = require("taskwarrior.taskmd")
      local uuid = taskmd.tw_add("regression test task", {})

      assert.equals("", uuid, "tw_add should return empty UUID when `task` is missing")
      assert.equals(0, #system_calls,
        "tw_add must not call vim.fn.system({\"task\",...}) when executable check fails; got "
          .. vim.inspect(system_calls))
    end)

    it("returns gracefully (no Lua error) for tw_add / tw_modify with missing binary", function()
      force_task_missing()
      vim.fn.system = function(_) return "" end

      package.loaded["taskwarrior.taskmd"] = nil
      local taskmd = require("taskwarrior.taskmd")

      local ok_add, err_add = pcall(taskmd.tw_add, "graceful", {})
      assert.is_true(ok_add, "tw_add must not raise; got: " .. tostring(err_add))

      local ok_mod, err_mod = pcall(taskmd.tw_modify, "deadbeef-dead-beef-dead-beefdeadbeef",
        { project = "x" })
      assert.is_true(ok_mod, "tw_modify must not raise; got: " .. tostring(err_mod))
    end)
  end)

  describe("Layer C: notify discipline", function()
    it("emits at most one missing-binary WARN per session (no spam)", function()
      force_task_missing()
      vim.fn.system = function(_) return "" end
      package.loaded["taskwarrior.taskmd"] = nil
      local taskmd = require("taskwarrior.taskmd")

      for _ = 1, 5 do taskmd.tw_add("spam test", {}) end

      local count = 0
      for _, n in ipairs(notifications) do
        if n.level == vim.log.levels.WARN
          and n.msg:match("[Tt]askwarrior")
          and (n.msg:match("not found") or n.msg:match("PATH")) then
          count = count + 1
        end
      end
      assert(count <= 1,
        "expected at most 1 missing-binary WARN per session, got " .. count
          .. ":\n" .. vim.inspect(notifications))
    end)
  end)
end)
