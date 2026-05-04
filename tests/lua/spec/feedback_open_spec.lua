-- tests/lua/spec/feedback_open_spec.lua
--
-- Regression spec for the "feedback bricked by default" bug noted in
-- docs/launch/feedback-flow-design.md. Pre-fix, feedback_endpoint
-- defaulted to `false` and M.open() early-returned on every default-
-- config install — bricking the GitHub-issue and clipboard paths that
-- need no endpoint. msakiart in issue #2 could not have used the
-- feedback flow even if they'd known about it.
--
-- Behavior locked in here:
--   * Default config opens the feedback form successfully.
--   * Explicit `feedback_endpoint = false` is treated as opt-out and
--     refuses to open (preserves the original opt-out semantic for
--     users who set it deliberately).
--   * task_count is reported via the DP bucket helper, never the raw
--     integer.

local function find_buf_by_name(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find(name, 1, true) then return b end
  end
  return nil
end

local function reset_modules()
  package.loaded["taskwarrior"] = nil
  package.loaded["taskwarrior.config"] = nil
  package.loaded["taskwarrior.feedback"] = nil
  package.loaded["taskwarrior.feedback.privacy"] = nil
end

describe("taskwarrior.feedback default behavior — bricked-default fix", function()
  local notify_log

  before_each(function()
    reset_modules()
    notify_log = {}
    -- We need a real notify hook so we can assert that "disabled" warnings
    -- DON'T fire under default config.
    _G._test_orig_notify = vim.notify
    vim.notify = function(msg, level, _opts)
      table.insert(notify_log, { msg = tostring(msg), level = level })
    end
  end)

  after_each(function()
    vim.notify = _G._test_orig_notify
    _G._test_orig_notify = nil
    -- Wipe any feedback buffer from this test.
    local fb = find_buf_by_name("taskwarrior.nvim Feedback")
    if fb then pcall(vim.api.nvim_buf_delete, fb, { force = true }) end
  end)

  describe("default config (no setup or empty setup)", function()
    it("M.open() opens the form buffer (does NOT no-op)", function()
      require("taskwarrior").setup({})
      require("taskwarrior.feedback").open()
      local buf = find_buf_by_name("taskwarrior.nvim Feedback")
      assert.is_not_nil(buf, "feedback buffer was not created on default config")
    end)

    it("M.open() under default config does NOT emit a 'disabled' WARN", function()
      require("taskwarrior").setup({})
      require("taskwarrior.feedback").open()
      for _, n in ipairs(notify_log) do
        assert.is_falsy(
          n.level == vim.log.levels.WARN
            and tostring(n.msg):lower():match("disabled"),
          "false-positive 'disabled' warning under default config: " .. n.msg
        )
      end
    end)
  end)

  describe("explicit opt-out is preserved", function()
    it("feedback_endpoint = false → form refuses to open with a clear notify", function()
      require("taskwarrior").setup({ feedback_endpoint = false })
      require("taskwarrior.feedback").open()
      local buf = find_buf_by_name("taskwarrior.nvim Feedback")
      assert.is_nil(buf, "feedback buffer should NOT open when explicitly opted out")
      local saw_disabled = false
      for _, n in ipairs(notify_log) do
        if n.level == vim.log.levels.WARN
          and tostring(n.msg):lower():match("disabled") then
          saw_disabled = true
        end
      end
      assert.is_true(saw_disabled,
        "explicit opt-out should produce a 'disabled' WARN; got: "
          .. vim.inspect(notify_log))
    end)
  end)

  describe("config default value", function()
    it("feedback_endpoint defaults to nil (not false)", function()
      require("taskwarrior").setup({})
      assert.is_nil(require("taskwarrior.config").options.feedback_endpoint,
        "feedback_endpoint default must be nil so the form opens; "
          .. "explicit `false` remains the opt-out signal")
    end)
  end)
end)

describe("taskwarrior.feedback build_payload — DP-bucketed task_count", function()
  before_each(function() reset_modules() end)

  it("client.task_count_bucket is a string from the privacy bucketer", function()
    require("taskwarrior").setup({})
    -- Reach into the module's private build_payload via our own copy of
    -- the same function — feedback.lua doesn't currently export it, so
    -- we exercise it indirectly by triggering handle_save with stubbed
    -- system calls. Simplest: reach into the module's upvalues by
    -- re-requiring and grabbing the public surface that uses it.
    local feedback = require("taskwarrior.feedback")
    -- Stub vim.fn.system so the `task --version` and `task count` calls
    -- return predictable strings without touching the real binary.
    local orig_system = vim.fn.system
    -- Reset shell_error to 0 via a real successful subprocess (vim.v.shell_error
    -- is read-only so we can't just assign it).
    orig_system("true")
    vim.fn.system = function(argv)
      local s = type(argv) == "table" and table.concat(argv, " ") or tostring(argv)
      if s:find("--version", 1, true) then return "task 3.4.2\n" end
      if s:find(" count", 1, true) or s:match("count$") then return "127\n" end
      return ""
    end

    -- Build payload via the public _build_payload export (added in this
    -- commit so tests can poke at it without monkey-patching internals).
    local payload = feedback._build_payload({
      what_happened = "x", expected = "y", other = "z",
    })

    vim.fn.system = orig_system

    assert.is_string(payload.client.task_count_bucket,
      "payload.client.task_count_bucket must be a string range; got "
        .. type(payload.client.task_count_bucket))
    assert.equals("101-500", payload.client.task_count_bucket,
      "127 should bucket as '101-500'; got " .. tostring(payload.client.task_count_bucket))
  end)

  it("payload does NOT include the raw task_count integer", function()
    require("taskwarrior").setup({})
    local feedback = require("taskwarrior.feedback")
    local orig_system = vim.fn.system
    orig_system("true")
    vim.fn.system = function(argv)
      local s = type(argv) == "table" and table.concat(argv, " ") or tostring(argv)
      if s:find("--version", 1, true) then return "task 3.4.2\n" end
      return "42\n"
    end

    local payload = feedback._build_payload({
      what_happened = "x", expected = "", other = "",
    })
    vim.fn.system = orig_system

    assert.is_nil(payload.client.task_count,
      "raw integer task_count must NOT be sent; only task_count_bucket")
  end)
end)
