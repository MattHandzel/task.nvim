-- runtime_oracle_lint_spec.lua — guards the single source of truth for
-- the `task` binary availability check.
--
-- Why: prior to v1.5 the plugin had four independent copies of
-- `vim.fn.executable("task") == 1`, and they drifted over time — the
-- Layer-A startup WARN fired correctly, but downstream call sites
-- (Python fallback, healthcheck data-location block) re-spawned `task`
-- and surfaced secondary errors. The fix was to centralise the check
-- in lua/taskwarrior/runtime.lua. This spec keeps the centralisation
-- enforced: any new `vim.fn.executable("task")` call outside runtime.lua
-- fails the suite, forcing the author to route through the oracle.

describe("runtime oracle — task-binary availability check", function()

  it("only lua/taskwarrior/runtime.lua may call vim.fn.executable('task')", function()
    -- Search every plugin Lua file for the literal pattern. fd is the
    -- repo's required search tool (see CLAUDE.md), but pure-Lua works
    -- too and avoids a hard dep on fd in CI: walk the trees ourselves.
    local roots = { "lua", "plugin" }
    local source = debug.getinfo(1, "S").source:sub(2)
    local repo_root = vim.fn.fnamemodify(source, ":h:h:h:h")

    local offenders = {}
    for _, root in ipairs(roots) do
      local files = vim.fn.glob(repo_root .. "/" .. root .. "/**/*.lua", true, true)
      for _, file in ipairs(files) do
        -- Allow-listed: the oracle module itself.
        if not file:match("/lua/taskwarrior/runtime%.lua$") then
          local fh = io.open(file, "r")
          if fh then
            local content = fh:read("*all")
            fh:close()
            -- Pattern: vim.fn.executable("task")  (any quoting / spacing)
            if content:match("vim%.fn%.executable%([\"']task[\"']%)") then
              table.insert(offenders, (file:gsub(repo_root .. "/", "")))
            end
          end
        end
      end
    end

    if #offenders > 0 then
      assert(false,
        "vim.fn.executable('task') found outside lua/taskwarrior/runtime.lua:\n  "
          .. table.concat(offenders, "\n  ")
          .. "\nRoute through require('taskwarrior.runtime').is_task_available()"
          .. " or .ensure_available() instead. See lua/taskwarrior/runtime.lua"
          .. " for the rationale."
      )
    end
  end)

  describe("oracle behavior", function()
    local runtime = require("taskwarrior.runtime")

    before_each(function()
      runtime._reset_for_tests()
    end)

    it("is_task_available caches the first lookup", function()
      -- Whatever the host system reports, two consecutive calls return
      -- the same value (no flicker, no stale lookup).
      local a = runtime.is_task_available()
      local b = runtime.is_task_available()
      assert.equals(a, b)
    end)

    it("ensure_available emits the WARN at most once per session", function()
      -- Stub vim.fn.executable so we control the outcome regardless of
      -- the host's PATH, then count notifications.
      local notifies = 0
      local orig_notify = vim.notify
      local orig_executable = vim.fn.executable
      vim.fn.executable = function(cmd) if cmd == "task" then return 0 end; return orig_executable(cmd) end
      vim.notify = function(_msg, _level) notifies = notifies + 1 end

      local ok1, ok2, ok3 = pcall(runtime.ensure_available),
                            pcall(runtime.ensure_available),
                            pcall(runtime.ensure_available)

      vim.notify = orig_notify
      vim.fn.executable = orig_executable

      assert.is_true(ok1 and ok2 and ok3)
      assert.equals(1, notifies, "expected exactly one WARN across three calls; got " .. notifies)
    end)

    it("MISSING_BINARY_MESSAGE is non-empty and references :checkhealth", function()
      assert.is_truthy(runtime.MISSING_BINARY_MESSAGE:find("checkhealth"))
      assert.is_truthy(runtime.MISSING_BINARY_MESSAGE:find("PATH"))
    end)
  end)
end)
