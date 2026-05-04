-- tests/lua/spec/smoke_user_flows_spec.lua
--
-- Smoke tests for every user-invokable flow the plugin exposes.
-- The bar: invoking the flow headlessly must not raise a Lua error.
--
-- This spec exists because of a v1.4.1 ship-time bug: invoking the
-- Tutor's "Show me the exact `task` commands first" path raised
-- `'replacement string' item contains newlines` from
-- nvim_buf_set_lines — code that NO unit test had ever exercised
-- because every prior spec verified primitives in isolation.
--
-- Rule going forward: every user-facing flow (popup, prompt, picker,
-- buffer rendering, command callback) must have one assertion here.
-- Unit tests verify pieces; smoke tests verify the journey.
--
-- These tests deliberately do not assert correctness of output — they
-- assert ABSENCE OF CRASH. If you want to verify what a flow produces,
-- write a feature spec. If you want to know whether it explodes when
-- you wire it up, write the smoke test here.

-- Capture genuine Lua / vim API errors that fire during a callback,
-- including ones thrown inside vim.schedule (the pattern that hid the
-- v1.4.1 verify-buffer bug). Distinguishes real errors from intentional
-- ERROR-level user notifications by matching on stack-trace markers and
-- vim error codes — a plugin emitting `vim.notify("foo", ERROR)` for a
-- legitimate user-facing message is NOT a test failure.
local function looks_like_real_error(msg)
  msg = tostring(msg or "")
  return msg:match("Error executing")
      or msg:match("stack traceback:")
      or msg:match("attempt to")
      or msg:match("^E%d+:")            -- :h E211 etc.
      or msg:match("'replacement string'")
end

local function trap_errors(fn)
  local errors = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, _level, _opts)
    if looks_like_real_error(msg) then
      table.insert(errors, tostring(msg))
    end
  end
  -- Catch direct throws from the function itself.
  local ok, err = pcall(fn)
  if not ok then table.insert(errors, tostring(err)) end
  -- Drain pending vim.schedule callbacks — bugs inside scheduled
  -- closures (the original bug class) would otherwise fire AFTER fn
  -- returned and miss the error trap.
  vim.wait(50, function() return false end)
  vim.notify = orig_notify
  return errors
end

local function reset_modules()
  for k in pairs(package.loaded) do
    if k:match("^taskwarrior") then package.loaded[k] = nil end
  end
end

describe("smoke: user-facing flows do not crash", function()
  before_each(function()
    reset_modules()
    -- Stub vim.ui.select / input so no flow blocks waiting for the user.
    vim.ui.select = function(_items, _opts, on_choice) on_choice(nil) end
    vim.ui.input  = function(_opts, on_input) on_input(nil) end
    require("taskwarrior").setup({})
  end)

  -- ─── Tutor flows ─────────────────────────────────────────────────────

  describe(":TaskTutor", function()
    it("M.start() — consent flow with auto-cancel does not crash", function()
      local errors = trap_errors(function()
        require("taskwarrior.tutor").start()
      end)
      assert.equals(0, #errors,
        "errors during M.start: " .. vim.inspect(errors))
    end)

    it("'Start the tutor' selection runs _begin_session cleanly", function()
      vim.ui.select = function(_items, _opts, on_choice)
        on_choice("Start the tutor")
      end
      local errors = trap_errors(function()
        require("taskwarrior.tutor").start()
      end)
      -- Best-effort cleanup so the next test is not polluted.
      pcall(require("taskwarrior.tutor")._cleanup)
      assert.equals(0, #errors,
        "errors when starting tutor session: " .. vim.inspect(errors))
    end)

    it("'Show me the exact `task` commands first' renders the verify buffer", function()
      -- THIS is the regression for the v1.4.1 ship-time bug:
      -- nvim_buf_set_lines rejected an element containing embedded \n
      -- because show_verify_buffer used table.concat with "\n  ".
      vim.ui.select = function(_items, _opts, on_choice)
        on_choice("Show me the exact `task` commands first")
      end
      local errors = trap_errors(function()
        require("taskwarrior.tutor").start()
      end)
      assert.equals(0, #errors,
        "errors when opening verify buffer (regression for v1.4.1 ship-time bug): "
          .. vim.inspect(errors))
    end)

    it("'Cancel' selection is a clean no-op", function()
      vim.ui.select = function(_items, _opts, on_choice)
        on_choice("Cancel")
      end
      local errors = trap_errors(function()
        require("taskwarrior.tutor").start()
      end)
      assert.equals(0, #errors,
        "errors on Cancel: " .. vim.inspect(errors))
    end)

    it("M.reset() does not crash with no active session", function()
      local errors = trap_errors(function()
        require("taskwarrior.tutor").reset()
      end)
      assert.equals(0, #errors,
        "errors on reset(): " .. vim.inspect(errors))
    end)

    it("rendering each lesson buffer does not crash", function()
      local tutor = require("taskwarrior.tutor")
      tutor._begin_session()
      local lessons = require("taskwarrior.tutor.lessons")
      local errors = {}
      for i = 1, lessons.count() do
        local errs = trap_errors(function()
          tutor._open_lesson_buffer(i)
        end)
        for _, e in ipairs(errs) do
          table.insert(errors, "lesson " .. i .. ": " .. e)
        end
      end
      pcall(tutor._cleanup)
      assert.equals(0, #errors, vim.inspect(errors))
    end)
  end)

  -- ─── Feedback flows ──────────────────────────────────────────────────

  describe(":TaskFeedback", function()
    it("M.open() does not crash on default config", function()
      local errors = trap_errors(function()
        require("taskwarrior.feedback").open()
      end)
      assert.equals(0, #errors,
        "errors during feedback.open: " .. vim.inspect(errors))
    end)

    it("M.last_error() does not crash with empty ring buffer", function()
      local errors = trap_errors(function()
        require("taskwarrior.feedback").last_error()
      end)
      assert.equals(0, #errors,
        "errors during last_error (empty ring): " .. vim.inspect(errors))
    end)

    it("M.last_error() does not crash with a captured ERROR", function()
      local notify = require("taskwarrior.notify")
      notify("error", "synthetic test error", vim.log.levels.ERROR)
      local errors = trap_errors(function()
        require("taskwarrior.feedback").last_error()
      end)
      assert.equals(0, #errors,
        "errors during last_error (with ERROR): " .. vim.inspect(errors))
    end)

    it("M.open_with_context(...) renders a multi-line context block", function()
      -- Specifically guards against the same nvim_buf_set_lines newline
      -- bug class — markdown_block contains "\n" deliberately.
      local errors = trap_errors(function()
        require("taskwarrior.feedback").open_with_context(
          "line one\nline two\nline three\n```\nfenced\n```")
      end)
      assert.equals(0, #errors,
        "errors during open_with_context: " .. vim.inspect(errors))
    end)
  end)

  -- ─── Buffer-context capture (g?) ─────────────────────────────────────

  describe("feedback.context.capture + format on a synthetic buffer", function()
    it("does not crash on a populated buffer", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "## Project Work",
        "- [ ] Fix login bug project:Work priority:H +urgent",
        "- [ ] Pay rent due:2026-04-01",
        "- [x] Already done",
      })
      vim.b[buf].taskwarrior_filter = "status:pending"
      local errors = trap_errors(function()
        local ctx = require("taskwarrior.feedback.context")
        local snap = ctx.capture(buf, 2)
        local md = ctx.format(snap)
        -- Exercise the same nvim_buf_set_lines path the g? handler hits.
        require("taskwarrior.feedback").open_with_context(md)
      end)
      assert.equals(0, #errors,
        "errors during g? capture+format+open: " .. vim.inspect(errors))
    end)
  end)

  -- ─── Notify dispatch under various levels ────────────────────────────

  describe("notify.lua dispatch", function()
    it("WARN, ERROR, and INFO all dispatch without crash", function()
      local notify = require("taskwarrior.notify")
      local errors = trap_errors(function()
        notify("apply",  "info-level message")
        notify("warn",   "warn-level message", vim.log.levels.WARN)
        notify("error",  "error-level message", vim.log.levels.ERROR)
      end)
      assert.equals(0, #errors,
        "errors during notify dispatch: " .. vim.inspect(errors))
    end)

    it("the appended hint text is well-formed (no embedded newline issues)", function()
      -- The hint appended to the first ERROR contains "\n" — verify
      -- it does not break any downstream consumer.
      local notify = require("taskwarrior.notify")
      notify._reset_hint()
      local captured
      local orig = vim.notify
      vim.notify = function(msg, _level, _opts) captured = tostring(msg) end
      notify("error", "boom", vim.log.levels.ERROR)
      vim.notify = orig
      assert.is_string(captured, "no notification was dispatched")
      assert.is_truthy(captured:match("Tip:"),
        "hint suffix missing from first ERROR; got: " .. tostring(captured))
    end)
  end)
end)
