-- tests/lua/spec/tutor_lessons_spec.lua
--
-- Structural correctness for the lessons module + the lesson API surface.
--
-- This spec complements tutor_isolation_spec.lua. Where that file enforces
-- "any temp dir the tutor creates must be sandboxed", this file enforces
-- "any `task` call a lesson makes must route through the sandboxed API."
--
-- Together they prevent the most likely future regression: a contributor
-- adds a new lesson, writes its validator with a direct `vim.fn.system`
-- call to `task`, and accidentally exfiltrates to the user's real DB.
-- That contributor will see this spec turn red.

describe("taskwarrior.tutor.lessons — structural", function()
  local lessons, tutor

  before_each(function()
    package.loaded["taskwarrior.tutor"] = nil
    package.loaded["taskwarrior.tutor.lessons"] = nil
    tutor   = require("taskwarrior.tutor")
    lessons = require("taskwarrior.tutor.lessons")
  end)

  after_each(function()
    if tutor and tutor._cleanup then pcall(tutor._cleanup) end
  end)

  describe("schema", function()
    it("ships at least 4 lessons", function()
      -- v1.4.1 ships 5 + graduation = 6. If we drop below 4, the tutor
      -- has lost its purpose.
      assert.is_true(lessons.count() >= 4,
        "tutor should ship at least 4 lessons; got " .. lessons.count())
    end)

    it("every lesson has id, title, and body", function()
      for i = 1, lessons.count() do
        local l = lessons.get(i)
        assert.is_string(l.id, "lesson " .. i .. " missing id")
        assert.is_string(l.title, "lesson " .. i .. " missing title")
        assert.is_table(l.body, "lesson " .. i .. " missing body")
        assert.is_true(#l.body > 0, "lesson " .. i .. " has empty body")
      end
    end)

    it("lesson ids are unique", function()
      local seen = {}
      for i = 1, lessons.count() do
        local id = lessons.get(i).id
        assert.is_nil(seen[id], "duplicate lesson id: " .. id)
        seen[id] = true
      end
    end)

    it("validate (when present) is a function", function()
      for i = 1, lessons.count() do
        local l = lessons.get(i)
        if l.validate ~= nil then
          assert.equals("function", type(l.validate),
            "lesson " .. i .. " (" .. l.id .. ") has non-function validate")
        end
      end
    end)

    it("skip_if (when present) is a function", function()
      for i = 1, lessons.count() do
        local l = lessons.get(i)
        if l.skip_if ~= nil then
          assert.equals("function", type(l.skip_if),
            "lesson " .. i .. " (" .. l.id .. ") has non-function skip_if")
        end
      end
    end)
  end)

  -- ── Lesson API — the structural invariant ────────────────────────────────
  --
  -- Lessons interact with Taskwarrior ONLY via the `api` table from
  -- lessons.make_api(tutor). Every method on that table must call the
  -- sandboxed argv prefix. Test by stubbing vim.fn.system and asserting
  -- the captured argv shape.

  describe("lessons.make_api", function()
    local original_system

    before_each(function() original_system = vim.fn.system end)
    after_each(function() vim.fn.system = original_system end)

    it("api.export() routes through tutor._task_argv_prefix", function()
      tutor._begin_session()
      -- Reset shell_error to 0 via a real successful subprocess so the
      -- lesson API's `if vim.v.shell_error ~= 0 then return {}` gate
      -- doesn't short-circuit. (vim.v.shell_error is read-only; we can't
      -- assign it, only mutate it indirectly via vim.fn.system.)
      original_system("true")
      local captured
      vim.fn.system = function(argv)
        captured = argv
        return "[]"
      end

      local api = lessons.make_api(tutor)
      api.export("status:pending")

      assert.is_table(captured, "vim.fn.system was not called")
      assert.equals("task", captured[1])

      local has_data_loc = false
      local has_hooks_off = false
      for _, a in ipairs(captured) do
        if a:match("^rc%.data%.location=") then has_data_loc = true end
        if a == "rc.hooks=off"             then has_hooks_off = true end
      end
      assert.is_true(has_data_loc,
        "api.export argv missing rc.data.location override; got " .. vim.inspect(captured))
      assert.is_true(has_hooks_off,
        "api.export argv missing rc.hooks=off; got " .. vim.inspect(captured))
    end)

    it("api.export rc.data.location points to the active session's tmp_dir", function()
      tutor._begin_session()
      original_system("true")
      local captured
      vim.fn.system = function(argv)
        captured = argv
        return "[]"
      end

      local api = lessons.make_api(tutor)
      api.export()

      local target_path
      for _, a in ipairs(captured) do
        local m = a:match("^rc%.data%.location=(.+)$")
        if m then target_path = m end
      end
      assert.equals(tutor._get_session().tmp_dir, target_path)
    end)

    it("api.export splits multi-word filters into separate argv elements", function()
      -- Regression for the "lesson 4 won't advance" bug. Taskwarrior treats
      -- each argv element as a separate token; a multi-word filter passed
      -- as ONE element (e.g. "status:completed description.contains:rent")
      -- comes through as a single weird token that doesn't apply either
      -- condition. The user marks the task done, the validator runs, and
      -- gets back zero results — they're stuck on the lesson.
      tutor._begin_session()
      original_system("true")
      local captured
      vim.fn.system = function(argv)
        captured = argv
        return "[]"
      end

      local api = lessons.make_api(tutor)
      api.export("status:completed description.contains:rent")

      -- Walk argv looking for the two filter tokens. They MUST be separate
      -- elements; finding the joined string means the bug is back.
      local has_status, has_desc, has_joined = false, false, false
      for _, a in ipairs(captured) do
        if a == "status:completed"             then has_status = true end
        if a == "description.contains:rent"    then has_desc   = true end
        if a == "status:completed description.contains:rent" then
          has_joined = true
        end
      end
      assert.is_true(has_status,
        "argv missing 'status:completed' as a separate element; got "
          .. vim.inspect(captured))
      assert.is_true(has_desc,
        "argv missing 'description.contains:rent' as a separate element; got "
          .. vim.inspect(captured))
      assert.is_false(has_joined,
        "filter was passed as a single joined token (the bug); got "
          .. vim.inspect(captured))
    end)

    it("api.pending_count routes through the sandboxed prefix", function()
      tutor._begin_session()
      original_system("true")
      local captured
      vim.fn.system = function(argv)
        captured = argv
        return "0\n"
      end

      local api = lessons.make_api(tutor)
      api.pending_count()

      local has_data_loc = false
      for _, a in ipairs(captured or {}) do
        if a:match("^rc%.data%.location=") then has_data_loc = true end
      end
      assert.is_true(has_data_loc,
        "api.pending_count argv missing rc.data.location; got " .. vim.inspect(captured))
    end)
  end)

  -- ── Validators don't crash when given an empty/empty-export DB ──────────

  describe("validators are crash-free against an empty sandbox", function()
    it("each lesson's validate returns false (or true, never errors) on empty DB", function()
      tutor._begin_session()
      local api = lessons.make_api(tutor)
      -- We can't actually run `task export` here without a real `task`
      -- binary, but we CAN stub vim.fn.system to return an empty array
      -- and assert no validator throws.
      local original = vim.fn.system
      original("true")  -- reset shell_error to 0
      vim.fn.system = function(_) return "[]" end

      for i = 1, lessons.count() do
        local l = lessons.get(i)
        if l.validate then
          local ok, result = pcall(l.validate, api)
          assert.is_true(ok,
            "lesson " .. i .. " (" .. l.id .. ") validate threw: " .. tostring(result))
          -- Result type must be boolean (allows the engine to make a decision).
          assert.is_true(result == true or result == false,
            "lesson " .. i .. " (" .. l.id .. ") returned non-boolean: " ..
            type(result) .. " " .. tostring(result))
        end
      end

      vim.fn.system = original
    end)
  end)
end)
