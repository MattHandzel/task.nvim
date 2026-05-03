-- tests/lua/spec/tutor_isolation_spec.lua
--
-- Structural invariants for taskwarrior.tutor — the interactive tutorial.
--
-- The tutor runs lessons against a throwaway Taskwarrior database. The
-- absolute, non-negotiable guarantee is that the user's real `~/.task`
-- and `~/.taskrc` are never touched. This spec encodes that guarantee
-- as machine-checked invariants so future code changes can't silently
-- break it.
--
-- The tests are independent of lesson content — they test the isolation
-- layer that ALL lessons must use. A new lesson author can't accidentally
-- exfiltrate to the user's real DB without breaking tests here.
--
-- See also: lua/taskwarrior/tutor/init.lua, docs in CLAUDE.md under
-- "Degraded environment" tier (added when this spec was written).

describe("taskwarrior.tutor — isolation invariants", function()
  local tutor

  before_each(function()
    -- Force-reload so each test gets a fresh module-local state table.
    -- The tutor uses module-local _session — without this reset, leaks
    -- from one test could mask bugs in another.
    package.loaded["taskwarrior.tutor"] = nil
    package.loaded["taskwarrior.tutor.init"] = nil
    tutor = require("taskwarrior.tutor")
  end)

  after_each(function()
    -- Belt-and-braces cleanup so a failing test can't poison its successor
    -- with an undeleted temp dir or stale autocmd.
    if tutor and tutor._cleanup then pcall(tutor._cleanup) end
    if tutor and tutor._cleanup_orphans then pcall(tutor._cleanup_orphans) end
  end)

  -- ── Lifecycle ────────────────────────────────────────────────────────────

  describe("session lifecycle", function()
    it("creates a temp dir and isolated .taskrc when session begins", function()
      tutor._begin_session()
      local s = tutor._get_session()
      assert.is_not_nil(s, "_get_session() returned nil after _begin_session()")
      assert.equals(1, vim.fn.isdirectory(s.tmp_dir),
        "tmp_dir not created at " .. tostring(s.tmp_dir))
      assert.equals(1, vim.fn.filereadable(s.taskrc),
        ".taskrc not created at " .. tostring(s.taskrc))
    end)

    it("temp dir contains a .taskrc with data.location pointing to itself", function()
      tutor._begin_session()
      local s = tutor._get_session()
      local rc = vim.fn.readfile(s.taskrc)
      local found_data_location = false
      for _, line in ipairs(rc) do
        if line:match("^data%.location=") then
          found_data_location = true
          local path = line:match("^data%.location=(.+)$")
          assert.equals(s.tmp_dir, path,
            "data.location must point to tmp_dir, got " .. tostring(path))
        end
      end
      assert.is_true(found_data_location, ".taskrc must set data.location")
    end)

    it("temp dir is wiped on _cleanup()", function()
      tutor._begin_session()
      local tmp = tutor._get_session().tmp_dir
      tutor._cleanup()
      assert.equals(0, vim.fn.isdirectory(tmp),
        "tmp_dir " .. tmp .. " survived _cleanup()")
    end)

    it("_cleanup is idempotent — second call is safe (no error)", function()
      tutor._begin_session()
      tutor._cleanup()
      assert.has_no.errors(function() tutor._cleanup() end)
    end)

    it("_cleanup before _begin_session is safe (no error, no state mutation)", function()
      assert.has_no.errors(function() tutor._cleanup() end)
      assert.is_nil(tutor._get_session())
    end)

    it("_get_session() returns nil after _cleanup", function()
      tutor._begin_session()
      tutor._cleanup()
      assert.is_nil(tutor._get_session())
    end)
  end)

  -- ── Argv prefix — the ONLY way the tutor talks to `task` ────────────────

  describe("task argv prefix — every call must include rc.data.location override", function()
    it("returns argv with rc.data.location pointing to the temp dir", function()
      tutor._begin_session()
      local argv = tutor._task_argv_prefix()
      assert.equals("task", argv[1])
      local found = false
      for _, a in ipairs(argv) do
        if a:match("^rc%.data%.location=") then
          found = true
          local path = a:match("^rc%.data%.location=(.+)$")
          assert.equals(tutor._get_session().tmp_dir, path,
            "rc.data.location must point to tmp_dir, got " .. path)
        end
      end
      assert.is_true(found,
        "argv must include rc.data.location override; got " .. vim.inspect(argv))
    end)

    it("argv prefix includes rc.hooks=off (block user hooks during tutor)", function()
      tutor._begin_session()
      local argv = tutor._task_argv_prefix()
      local found = false
      for _, a in ipairs(argv) do if a == "rc.hooks=off" then found = true; break end end
      assert.is_true(found, "argv must include rc.hooks=off; got " .. vim.inspect(argv))
    end)

    it("argv prefix includes rc.confirmation=no (no interactive prompts)", function()
      tutor._begin_session()
      local argv = tutor._task_argv_prefix()
      local found = false
      for _, a in ipairs(argv) do if a == "rc.confirmation=no" then found = true; break end end
      assert.is_true(found, "argv must include rc.confirmation=no")
    end)

    it("calling _task_argv_prefix without an active session errors clearly", function()
      -- No _begin_session call.
      local ok, err = pcall(tutor._task_argv_prefix)
      assert.is_false(ok, "should error when no active session")
      assert.is_truthy(tostring(err):match("session"),
        "error message should mention 'session'; got " .. tostring(err))
    end)
  end)

  -- ── Process-environment isolation ────────────────────────────────────────

  describe("environmental isolation — never mutate nvim's process state", function()
    it("does not set vim.env.TASKDATA on session start", function()
      local before = vim.env.TASKDATA
      tutor._begin_session()
      assert.equals(before, vim.env.TASKDATA,
        "tutor must not mutate vim.env.TASKDATA")
    end)

    it("does not set vim.env.TASKRC on session start", function()
      local before = vim.env.TASKRC
      tutor._begin_session()
      assert.equals(before, vim.env.TASKRC,
        "tutor must not mutate vim.env.TASKRC")
    end)

    it("does not modify config.options", function()
      local config = require("taskwarrior.config")
      config.setup({})
      local before = vim.deepcopy(config.options)
      tutor._begin_session()
      assert.same(before, config.options,
        "tutor must not mutate config.options")
    end)
  end)

  -- ── Early exit — every realistic exit path must clean up ────────────────

  describe("early exit — all exit paths trigger cleanup", function()
    it("BufWipeout on the tutor lesson buffer triggers _cleanup", function()
      tutor._begin_session()
      local s = tutor._get_session()
      assert.is_truthy(s.buf_ids and s.buf_ids[1],
        "session must register the lesson buffer in buf_ids")
      local buf = s.buf_ids[1]
      local tmp = s.tmp_dir

      vim.api.nvim_buf_delete(buf, { force = true })
      -- BufWipeout autocmd may schedule cleanup; flush.
      vim.wait(50, function() return tutor._get_session() == nil end)

      assert.equals(0, vim.fn.isdirectory(tmp),
        "tmp_dir survived BufWipeout on lesson buffer")
      assert.is_nil(tutor._get_session(),
        "session should be nil after BufWipeout-triggered cleanup")
    end)

    it("_simulate_vim_leave fires VimLeavePre handler and cleans up", function()
      tutor._begin_session()
      local tmp = tutor._get_session().tmp_dir
      -- Test hook to fire the same callback registered with VimLeavePre.
      tutor._simulate_vim_leave()
      assert.equals(0, vim.fn.isdirectory(tmp),
        "tmp_dir survived simulated VimLeavePre")
      assert.is_nil(tutor._get_session())
    end)

    it("cleanup after BufWipeout doesn't error if user closes buffer twice", function()
      tutor._begin_session()
      local buf = tutor._get_session().buf_ids[1]
      vim.api.nvim_buf_delete(buf, { force = true })
      vim.wait(50)
      -- Already cleaned up; nothing to delete. Must not throw.
      assert.has_no.errors(function() tutor._cleanup() end)
    end)
  end)

  -- ── Singleton — second start must not leak the first temp dir ───────────

  describe("singleton — two sessions don't leak the first", function()
    it("_begin_session after explicit _cleanup leaves no orphan", function()
      tutor._begin_session()
      local first_tmp = tutor._get_session().tmp_dir
      tutor._cleanup()
      tutor._begin_session()
      local second_tmp = tutor._get_session().tmp_dir

      assert.are_not.equals(first_tmp, second_tmp,
        "second session must use a different tmp_dir")
      assert.equals(0, vim.fn.isdirectory(first_tmp),
        "first tmp_dir leaked after second session start")
    end)

    it("calling _begin_session while one is active does not silently leak", function()
      tutor._begin_session()
      local first_tmp = tutor._get_session().tmp_dir
      -- The high-level :TaskTutor handler prompts the user; the low-level
      -- _begin_session must either refuse OR cleanly replace. Either way,
      -- the first tmp_dir must not survive on disk if the call succeeds.
      local ok = pcall(tutor._begin_session)
      if ok then
        assert.equals(0, vim.fn.isdirectory(first_tmp),
          "first tmp_dir leaked on second _begin_session call")
      end
      -- If the call refuses, the first session is still active and clean.
    end)
  end)

  -- ── Orphan detection (post-crash recovery) ──────────────────────────────

  describe("orphan detection", function()
    local function make_orphan()
      local fake = vim.fn.tempname() .. "_tw_tutor_orphan"
      vim.fn.mkdir(fake, "p")
      vim.fn.writefile({ "data.location=" .. fake, "hooks=off" }, fake .. "/.taskrc")
      return fake
    end

    it("_scan_orphans finds previously-leaked tutor temp dirs", function()
      local fake = make_orphan()
      local orphans = tutor._scan_orphans()
      assert.is_table(orphans, "_scan_orphans must return a table")
      local found = false
      for _, p in ipairs(orphans) do if p == fake then found = true end end
      assert.is_true(found,
        "_scan_orphans missed " .. fake .. "; returned " .. vim.inspect(orphans))
      vim.fn.delete(fake, "rf")
    end)

    it("_cleanup_orphans deletes scanned orphan dirs", function()
      local fake = make_orphan()
      tutor._cleanup_orphans()
      assert.equals(0, vim.fn.isdirectory(fake),
        "orphan " .. fake .. " survived _cleanup_orphans")
    end)

    it("_scan_orphans does not include the active session's tmp_dir", function()
      tutor._begin_session()
      local active = tutor._get_session().tmp_dir
      local orphans = tutor._scan_orphans()
      for _, p in ipairs(orphans) do
        assert.are_not.equals(active, p,
          "_scan_orphans must NOT classify the active session as orphan")
      end
    end)
  end)
end)
