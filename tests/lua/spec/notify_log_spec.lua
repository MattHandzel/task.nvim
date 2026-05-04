-- tests/lua/spec/notify_log_spec.lua
--
-- Module-private ring buffer in lua/taskwarrior/notify.lua. Captures
-- the last N WARN/ERROR notifications so the feedback flow can
-- auto-fill "Recent log entries" without forcing the user to copy
-- from :messages.
--
-- Design rules (also enforced by tests):
--   * Captures only notifications routed through taskwarrior.notify().
--     Never observes other plugins' notifications.
--   * Captures WARN+ only. INFO is noise (every successful apply, etc.)
--     and would balloon the report with no signal.
--   * FIFO eviction at the configured cap.
--   * The buffer is module-private. Reset is per-module-reload.

local function reset()
  package.loaded["taskwarrior.notify"] = nil
  package.loaded["taskwarrior.config"] = nil
end

describe("taskwarrior.notify ring buffer", function()
  local notify, original_vim_notify

  before_each(function()
    reset()
    notify = require("taskwarrior.notify")
    require("taskwarrior.config").setup({})  -- defaults
    -- Stub vim.notify so we don't pollute test output. We only want to
    -- assert what was captured in the ring buffer, not what was emitted
    -- to the user-facing notify channel.
    original_vim_notify = vim.notify
    vim.notify = function(_, _) end
  end)

  after_each(function()
    vim.notify = original_vim_notify
    reset()
  end)

  describe("capture rules", function()
    it("captures ERROR notifications", function()
      notify("error", "boom", vim.log.levels.ERROR)
      local entries = notify.recent()
      assert.equals(1, #entries, "expected 1 captured entry, got " .. #entries)
      assert.equals("boom", entries[1].msg)
      assert.equals(vim.log.levels.ERROR, entries[1].level)
    end)

    it("captures WARN notifications", function()
      notify("warn", "careful", vim.log.levels.WARN)
      local entries = notify.recent()
      assert.equals(1, #entries)
      assert.equals(vim.log.levels.WARN, entries[1].level)
    end)

    it("does NOT capture INFO notifications", function()
      notify("apply", "applied 3 changes")  -- default level INFO
      local entries = notify.recent()
      assert.equals(0, #entries,
        "INFO must not be captured; got " .. vim.inspect(entries))
    end)

    it("each entry carries a timestamp (epoch seconds)", function()
      local before = os.time()
      notify("error", "boom", vim.log.levels.ERROR)
      local e = notify.recent()[1]
      assert.is_number(e.timestamp,
        "entry should carry a numeric timestamp; got " .. type(e.timestamp))
      assert.is_true(e.timestamp >= before,
        "timestamp " .. e.timestamp .. " is earlier than os.time() before call")
    end)
  end)

  describe("FIFO eviction at cap", function()
    it("default cap is 10 entries", function()
      for i = 1, 15 do
        notify("error", "msg " .. i, vim.log.levels.ERROR)
      end
      local entries = notify.recent()
      assert.equals(10, #entries,
        "expected 10 entries (FIFO eviction at cap); got " .. #entries)
    end)

    it("oldest entries are evicted; newest are retained", function()
      for i = 1, 15 do
        notify("error", "msg " .. i, vim.log.levels.ERROR)
      end
      local entries = notify.recent()
      -- Newest first OR newest last? Document the chosen ordering
      -- by inspecting both ends.
      local first_msg = entries[1].msg
      local last_msg  = entries[#entries].msg
      -- Either ordering is fine; just assert that "msg 6"..."msg 15"
      -- are the surviving range.
      local seen = {}
      for _, e in ipairs(entries) do seen[e.msg] = true end
      for i = 6, 15 do
        assert.is_true(seen["msg " .. i],
          ("expected 'msg %d' to survive; got %s"):format(i, vim.inspect(entries)))
      end
      for i = 1, 5 do
        assert.is_falsy(seen["msg " .. i],
          ("expected 'msg %d' to be evicted; got %s"):format(i, vim.inspect(entries)))
      end
    end)
  end)

  describe("isolation — does not observe other plugins' notify", function()
    it("a direct vim.notify(...) call from outside the module is NOT captured", function()
      -- Restore the real vim.notify briefly to fire a notification that
      -- mimics another plugin's call. Then re-stub so the test output
      -- stays clean.
      vim.notify = original_vim_notify
      vim.notify("from another plugin", vim.log.levels.ERROR)
      vim.notify = function(_, _) end
      local entries = notify.recent()
      assert.equals(0, #entries,
        "the ring buffer must not capture notifications from outside taskwarrior.notify; got "
          .. vim.inspect(entries))
    end)
  end)

  describe("disable via config", function()
    it("setup({ feedback = { capture_log = false } }) → no capture", function()
      reset()
      notify = require("taskwarrior.notify")
      require("taskwarrior.config").setup({ feedback = { capture_log = false } })
      notify("error", "boom", vim.log.levels.ERROR)
      assert.equals(0, #notify.recent(),
        "capture_log = false must disable capture entirely")
    end)
  end)

  describe("recent() returns a copy, not a reference", function()
    it("mutating the returned table does not affect the buffer", function()
      notify("error", "boom", vim.log.levels.ERROR)
      local copy = notify.recent()
      copy[1].msg = "MUTATED"
      local fresh = notify.recent()
      assert.equals("boom", fresh[1].msg,
        "recent() must return a copy so external mutation can't corrupt state")
    end)
  end)
end)
