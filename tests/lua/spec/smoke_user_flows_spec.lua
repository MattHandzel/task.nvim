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

    -- 'Show me the exact `task` commands first' was removed in v1.5
    -- (its prompt-line was the worst offender for picker truncation
    -- and the option was never used by typical first-run users).
    -- The prior regression test against the v1.4.1 verify-buffer
    -- newline bug is no longer applicable.

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

-- ─────────────────────────────────────────────────────────────────────────
-- Deep flow assertions — beyond "no crash"
--
-- The smoke specs above cover absence-of-crash. These specs go further
-- and assert ACTUAL STATE: cursor position, registered keymaps, buffer
-- contents matching expected templates, skip_if advancement, the
-- post-:w action picker. Each is a test I should have run by hand
-- before claiming v1.4.1 was ready.
-- ─────────────────────────────────────────────────────────────────────────

describe("deep: tutor flows", function()
  before_each(function()
    reset_modules()
    vim.ui.select = function(_items, _opts, on_choice) on_choice(nil) end
    vim.ui.input  = function(_opts, on_input) on_input(nil) end
    require("taskwarrior").setup({})
  end)

  after_each(function()
    pcall(require("taskwarrior.tutor")._cleanup)
    -- Wipe any verify buffer left over from this test so the next one
    -- doesn't find a stale match.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
        local lines = vim.api.nvim_buf_get_lines(b, 0, 5, false)
        if lines[1] and lines[1]:match("Tutor verification") then
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
    end
  end)

  it("after 'Start the tutor', a [TaskTutor] buffer exists and is shown", function()
    vim.ui.select = function(_items, _opts, on_choice) on_choice("Start the tutor") end
    require("taskwarrior.tutor").start()
    local buf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find("[TaskTutor]", 1, true) then buf = b; break end
    end
    assert.is_not_nil(buf, "no [TaskTutor] buffer found after Start")
    -- And it should be visible in some window.
    assert.is_truthy(#vim.fn.win_findbuf(buf) > 0, "tutor buffer is not displayed")
  end)

  it("the lesson buffer has buffer-local <CR>, r, s, q keymaps", function()
    vim.ui.select = function(_items, _opts, on_choice) on_choice("Start the tutor") end
    require("taskwarrior.tutor").start()
    local buf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find("[TaskTutor]", 1, true) then buf = b; break end
    end
    assert.is_not_nil(buf)
    local maps = vim.api.nvim_buf_get_keymap(buf, "n")
    local lhs_set = {}
    for _, m in ipairs(maps) do lhs_set[m.lhs] = true end
    for _, key in ipairs({ "<CR>", "r", "s", "q" }) do
      assert.is_true(lhs_set[key] == true,
        ("expected buffer-local '%s' keymap on the lesson buffer; got %s")
          :format(key, vim.inspect(vim.tbl_keys(lhs_set))))
    end
  end)

  it("lesson 2 (Install Taskwarrior) auto-skips when `task` is on PATH", function()
    -- The CI/test env always has `task` installed (the e2e harness needs
    -- it). So lesson 2's skip_if must auto-advance us off lesson 2.
    local tutor = require("taskwarrior.tutor")
    tutor._begin_session()
    tutor._open_lesson_buffer(2)
    -- Auto-skip is scheduled via vim.schedule; flush.
    vim.wait(100, function() return tutor._get_session().lesson_idx ~= 2 end)
    assert.is_truthy(tutor._get_session().lesson_idx ~= 2,
      "lesson 2 should auto-skip when task is on PATH; stuck on idx "
        .. tostring(tutor._get_session().lesson_idx))
  end)

  it("graduating past the last lesson cleans up the session", function()
    local tutor = require("taskwarrior.tutor")
    tutor._begin_session()
    local lessons = require("taskwarrior.tutor.lessons")
    -- Open one past the last lesson — the render code routes to _graduate.
    tutor._open_lesson_buffer(lessons.count() + 1)
    -- _graduate calls _cleanup which sets _session = nil.
    assert.is_nil(tutor._get_session(),
      "session should be nil after graduation; still active")
  end)

  it("`q` keymap on lesson buffer cleans up the session", function()
    vim.ui.select = function(_items, _opts, on_choice) on_choice("Start the tutor") end
    local tutor = require("taskwarrior.tutor")
    tutor.start()
    assert.is_not_nil(tutor._get_session(), "no session after start")
    tutor._quit()
    assert.is_nil(tutor._get_session(), "_quit should null out the session")
  end)

  -- The 'Show me the exact `task` commands first' picker option and
  -- the verify-buffer it opened were removed in v1.5 (the prompt's
  -- multi-line copy was the worst-truncated by picker frontends, and
  -- the option was virtually never used). Tests for that flow have
  -- been deleted.
end)

describe("deep: feedback flows", function()
  before_each(function()
    reset_modules()
    vim.ui.select = function(_items, _opts, on_choice) on_choice(nil) end
    vim.ui.input  = function(_opts, on_input) on_input(nil) end
    require("taskwarrior").setup({})
  end)

  after_each(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find("Feedback", 1, true) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end)

  local function find_feedback_buf()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find("taskwarrior.nvim Feedback", 1, true) then
        return b
      end
    end
  end

  it("feedback form contains the four required template sections", function()
    require("taskwarrior.feedback").open()
    local buf = find_feedback_buf()
    assert.is_not_nil(buf, "feedback buffer not opened")
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    for _, header in ipairs({
      "# taskwarrior.nvim feedback",
      "## What happened%?",
      "## What did you expect%?",
      "## Anything else%?",
    }) do
      assert.is_truthy(content:find(header),
        "missing header: " .. header .. "\n--- buffer content ---\n" .. content)
    end
  end)

  it("cursor lands on the line right after '## What happened?'", function()
    require("taskwarrior.feedback").open()
    local buf = find_feedback_buf()
    assert.is_not_nil(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local what_lnum
    for i, l in ipairs(lines) do
      if l:match("^## What happened%?") then what_lnum = i; break end
    end
    assert.is_not_nil(what_lnum, "no '## What happened?' line in template")
    local cursor = vim.api.nvim_win_get_cursor(0)
    assert.equals(what_lnum + 1, cursor[1],
      ("cursor should be on line %d (right after '## What happened?'); got %d")
        :format(what_lnum + 1, cursor[1]))
  end)

  it("BufWriteCmd is registered on the feedback buffer", function()
    require("taskwarrior.feedback").open()
    local buf = find_feedback_buf()
    assert.is_not_nil(buf)
    local autocmds = vim.api.nvim_get_autocmds({ event = "BufWriteCmd", buffer = buf })
    assert.is_true(#autocmds > 0,
      "no BufWriteCmd registered on feedback buffer (form will not handle :w)")
  end)

  it("`q` on the feedback buffer wipes it cleanly", function()
    require("taskwarrior.feedback").open()
    local buf = find_feedback_buf()
    assert.is_not_nil(buf)
    -- The keymap is `q` -> `:bwipeout!`. Run it.
    vim.api.nvim_buf_call(buf, function() vim.cmd("normal q") end)
    -- Buffer should now be invalid.
    assert.is_false(vim.api.nvim_buf_is_valid(buf),
      "q keymap did not wipe the feedback buffer")
  end)

  it("last_error prefills 'What happened?' with the most-recent ERROR text", function()
    local notify   = require("taskwarrior.notify")
    local feedback = require("taskwarrior.feedback")
    notify("error", "OLD error",     vim.log.levels.ERROR)
    notify("warn",  "intervening",   vim.log.levels.WARN)
    notify("error", "RECENT error",  vim.log.levels.ERROR)

    feedback.last_error()

    local buf = find_feedback_buf()
    assert.is_not_nil(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- The "What happened?" header is followed by ONE line with the
    -- prefill (template's blank line is replaced by the prefill).
    local prefill_line
    for i, l in ipairs(lines) do
      if l:match("^## What happened%?") then
        prefill_line = lines[i + 1]
        break
      end
    end
    assert.is_string(prefill_line, "no line after '## What happened?'")
    assert.is_truthy(prefill_line:find("RECENT error", 1, true),
      "prefill should contain the RECENT error text; got: " .. tostring(prefill_line))
    assert.is_nil(prefill_line:find("OLD error", 1, true),
      "prefill should NOT contain the OLD error text; got: " .. tostring(prefill_line))
  end)

  it("open_with_context drops a multi-line markdown block under '## Anything else?'", function()
    local feedback = require("taskwarrior.feedback")
    local block = "Buffer context (sanitized):\n\n```\n- [ ] aaa\n- [ ] aaaa\n```"
    feedback.open_with_context(block)
    local buf = find_feedback_buf()
    assert.is_not_nil(buf)
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.is_truthy(content:find("Buffer context", 1, true),
      "context block not inserted into feedback buffer")
    assert.is_truthy(content:find("- %[ %] aaa"),
      "scrubbed sample line missing from inserted block")
  end)

  it(":w on the feedback buffer with no 'What happened' content surfaces a WARN, not a crash", function()
    -- The user opens the form, hits :w without filling anything in.
    -- Should warn "What happened? is required", not crash.
    --
    -- Note on notify capture: trap_errors installs its own vim.notify
    -- stub and restores at end. To observe specific user-facing notifies
    -- AND check for crash, we capture all notifies into a list and
    -- inspect after.
    require("taskwarrior.feedback").open()
    local buf = find_feedback_buf()
    assert.is_not_nil(buf)
    local notes = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level, _opts)
      table.insert(notes, { msg = tostring(msg), level = level })
    end
    local ok, err = pcall(function()
      vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
    end)
    vim.wait(50, function() return false end)
    vim.notify = orig_notify

    assert.is_true(ok, "empty :w threw: " .. tostring(err))
    -- Look for the required-field warn AND the absence of any real Lua error.
    local saw_required, saw_real_error = false, nil
    for _, n in ipairs(notes) do
      if n.msg:lower():match("what happened") then saw_required = true end
      if looks_like_real_error(n.msg) then saw_real_error = n.msg end
    end
    assert.is_nil(saw_real_error,
      "real error surfaced during empty :w: " .. tostring(saw_real_error))
    assert.is_true(saw_required,
      "should have warned 'What happened? is required'; got: " .. vim.inspect(notes))
  end)

  it(":w with content shows the post-save action picker (and Cancel works)", function()
    require("taskwarrior.feedback").open()
    local buf = find_feedback_buf()
    assert.is_not_nil(buf)
    -- Fill in 'What happened?'
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:match("^## What happened%?") then
        vim.api.nvim_buf_set_lines(buf, i, i + 1, false, { "", "I hit a bug." })
        break
      end
    end
    -- Stub the picker to pick Cancel.
    local picker_choices
    vim.ui.select = function(items, _opts, on_choice)
      picker_choices = items
      on_choice("Cancel")
    end
    local errors = trap_errors(function()
      vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
    end)
    assert.equals(0, #errors,
      "errors during filled :w + Cancel: " .. vim.inspect(errors))
    assert.is_table(picker_choices, "picker was never shown")
    -- Default config has no feedback_endpoint → no 'Send' option.
    -- We expect at least 'Open as GitHub issue', 'Copy payload to clipboard', 'Cancel'.
    local set = {}
    for _, c in ipairs(picker_choices) do set[c] = true end
    assert.is_true(set["Open as GitHub issue"] == true,
      "picker missing 'Open as GitHub issue'; got " .. vim.inspect(picker_choices))
    assert.is_true(set["Copy payload to clipboard"] == true,
      "picker missing 'Copy payload to clipboard'")
    assert.is_true(set["Cancel"] == true, "picker missing 'Cancel'")
    assert.is_nil(set["Send"],
      "picker should NOT show 'Send' when no feedback_endpoint is configured; got "
        .. vim.inspect(picker_choices))
  end)

  it("'## Anything else?' header in template matches the regex used by open_with_context", function()
    -- Regression guard: if someone changes the template's "Anything else?"
    -- wording, the open_with_context insertion (which matches on
    -- ^## Anything else) silently no-ops. This test pairs the two.
    require("taskwarrior.feedback").open()
    local buf = find_feedback_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local found
    for _, l in ipairs(lines) do
      if l:match("^## Anything else") then found = true; break end
    end
    assert.is_true(found,
      "template has no header matching ^## Anything else — open_with_context will silently no-op")
  end)
end)

describe("deep: g? in :Task buffers wires correctly", function()
  before_each(function()
    reset_modules()
    vim.ui.select = function(_items, _opts, on_choice) on_choice(nil) end
    vim.ui.input  = function(_opts, on_input) on_input(nil) end
    require("taskwarrior").setup({})
  end)

  it("g? on a setup_buf_keymaps buffer triggers feedback.open_with_context", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "## Project Work",
      "- [ ] Foo project:Work +urgent",
    })
    require("taskwarrior.buffer").setup_buf_keymaps(buf)
    -- We can't easily fire g? in headless without a window switch, so
    -- assert the keymap exists with the right callback target by
    -- inspecting the registered map.
    local maps = vim.api.nvim_buf_get_keymap(buf, "n")
    local g_question
    for _, m in ipairs(maps) do
      if m.lhs == "g?" then g_question = m; break end
    end
    assert.is_not_nil(g_question, "g? not registered on :Task-style buffer")
    assert.is_truthy(g_question.desc and g_question.desc:lower():match("bug"),
      "g? desc should mention 'bug' for :TaskHelp discoverability; got: "
        .. tostring(g_question.desc))
  end)

  it("firing `g?` for real opens the feedback form with sanitized context", function()
    -- Catches the entire pipeline end-to-end: keymap fires →
    -- vim.ui.select shows the picker → user picks scrambled →
    -- context.capture runs against a real buffer → context.format
    -- builds a markdown block → feedback.open_with_context inserts
    -- it. Any breakage in the chain shows up here.
    local task_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(task_buf, 0, -1, false, {
      "## Project Work",
      "- [ ] Sensitive description text project:Work priority:H +urgent",
      "- [ ] Pay rent due:2026-04-01 +bills",
    })
    -- Use the canonical buffer-var names exported by buf_vars (writer in
    -- buffer.lua sets these same vars on real :Tw buffers).
    local buf_vars = require("taskwarrior.buf_vars")
    vim.b[task_buf][buf_vars.FILTER] = "status:pending"
    vim.b[task_buf][buf_vars.SORT]   = "urgency-"
    vim.b[task_buf][buf_vars.GROUP]  = "project"
    require("taskwarrior.buffer").setup_buf_keymaps(task_buf)

    -- Move task_buf into the current window and put cursor on line 2.
    vim.api.nvim_win_set_buf(0, task_buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    -- Stub the new picker prompt to pick "scrambled" (the default).
    vim.ui.select = function(items, _opts, on_choice)
      for _, c in ipairs(items) do
        if c:match("^Include scrambled") then on_choice(c); return end
      end
      on_choice(items[1])
    end

    -- Fire g? via :normal — runs the buffer-local keymap.
    local errors = trap_errors(function() vim.cmd("normal g?") end)
    assert.equals(0, #errors,
      "errors during real g? fire: " .. vim.inspect(errors))

    -- Find the resulting feedback buffer and verify the context block
    -- landed in "## Anything else?".
    local fb_buf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find("taskwarrior.nvim Feedback", 1, true) then
        fb_buf = b; break
      end
    end
    assert.is_not_nil(fb_buf, "g? did not open the feedback form")

    local content = table.concat(vim.api.nvim_buf_get_lines(fb_buf, 0, -1, false), "\n")
    assert.is_truthy(content:find("Buffer context", 1, true),
      "feedback form missing 'Buffer context' header from g? capture")
    -- The capture metadata must be present.
    assert.is_truthy(content:find("filter:", 1, true), "missing filter: line")
    assert.is_truthy(content:find("status:pending", 1, true), "missing filter value")
    -- The structural tokens from line 2 must be preserved verbatim.
    assert.is_truthy(content:find("project:Work", 1, true),
      "project:Work should be preserved verbatim in capture")
    assert.is_truthy(content:find("+urgent", 1, true),
      "+urgent tag should be preserved verbatim in capture")
    -- The free-form description must NOT be present.
    assert.is_nil(content:find("Sensitive", 1, true),
      "free-form description leaked into feedback form (privacy violation): "
        .. content)

    pcall(vim.api.nvim_buf_delete, fb_buf,   { force = true })
    pcall(vim.api.nvim_buf_delete, task_buf, { force = true })
  end)

  -- Cover each of the three picker options by firing g? with each
  -- choice and asserting the form's resulting state.
  local function setup_task_buf_with_sensitive_data()
    local task_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(task_buf, 0, -1, false, {
      "## Project Work",
      "- [ ] Sensitive description text project:Work priority:H +urgent",
    })
    require("taskwarrior.buffer").setup_buf_keymaps(task_buf)
    vim.api.nvim_win_set_buf(0, task_buf)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    return task_buf
  end

  local function find_feedback_buf()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find("Feedback", 1, true) then return b end
    end
  end

  local function pick_choice(prefix)
    vim.ui.select = function(items, _opts, on_choice)
      for _, c in ipairs(items) do
        if c:lower():find(prefix:lower(), 1, true) then on_choice(c); return end
      end
      on_choice(nil)
    end
  end

  it("g? picker: 'scrambled' → form has scrubbed context, no leak", function()
    local task_buf = setup_task_buf_with_sensitive_data()
    pick_choice("scrambled")
    trap_errors(function() vim.cmd("normal g?") end)
    local fb = find_feedback_buf()
    assert.is_not_nil(fb, "form did not open after picking scrambled")
    local content = table.concat(vim.api.nvim_buf_get_lines(fb, 0, -1, false), "\n")
    assert.is_truthy(content:lower():match("sanitiz")
                  or content:lower():match("scrambl"),
      "scrambled context block should advertise sanitization in its header")
    assert.is_nil(content:find("Sensitive", 1, true),
      "scrambled mode leaked the original description; got:\n" .. content)
    pcall(vim.api.nvim_buf_delete, fb,       { force = true })
    pcall(vim.api.nvim_buf_delete, task_buf, { force = true })
  end)

  it("g? picker: 'ORIGINAL' → form contains the actual description", function()
    local task_buf = setup_task_buf_with_sensitive_data()
    pick_choice("original")
    trap_errors(function() vim.cmd("normal g?") end)
    local fb = find_feedback_buf()
    assert.is_not_nil(fb, "form did not open after picking ORIGINAL")
    local content = table.concat(vim.api.nvim_buf_get_lines(fb, 0, -1, false), "\n")
    assert.is_truthy(content:lower():match("original")
                  or content:lower():match("descriptions visible")
                  or content:lower():match("review"),
      "ORIGINAL header should warn the user that descriptions are visible; got:\n"
        .. content:sub(1, 800))
    assert.is_truthy(content:find("Sensitive description text", 1, true),
      "ORIGINAL mode should preserve the actual description; got:\n" .. content)
    pcall(vim.api.nvim_buf_delete, fb,       { force = true })
    pcall(vim.api.nvim_buf_delete, task_buf, { force = true })
  end)

  it("g? picker: 'No buffer context' → form opens with NO buffer block", function()
    local task_buf = setup_task_buf_with_sensitive_data()
    pick_choice("no buffer")
    trap_errors(function() vim.cmd("normal g?") end)
    local fb = find_feedback_buf()
    assert.is_not_nil(fb, "form did not open after picking 'No buffer context'")
    local content = table.concat(vim.api.nvim_buf_get_lines(fb, 0, -1, false), "\n")
    assert.is_nil(content:find("Buffer context", 1, true),
      "No-context choice should NOT insert a buffer-context block; got:\n"
        .. content:sub(1, 800))
    assert.is_nil(content:find("Sensitive", 1, true),
      "No-context choice should never include description text")
    pcall(vim.api.nvim_buf_delete, fb,       { force = true })
    pcall(vim.api.nvim_buf_delete, task_buf, { force = true })
  end)

  it("g? picker: nil/cancel → no form opens", function()
    local task_buf = setup_task_buf_with_sensitive_data()
    vim.ui.select = function(_items, _opts, on_choice) on_choice(nil) end
    trap_errors(function() vim.cmd("normal g?") end)
    assert.is_nil(find_feedback_buf(),
      "Cancel should not open the feedback form")
    pcall(vim.api.nvim_buf_delete, task_buf, { force = true })
  end)
end)
