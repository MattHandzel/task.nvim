-- tests/lua/spec/feedback_hint_spec.lua
--
-- Three intertwined behaviors for the easy-feedback flow:
--   1. The first ERROR per nvim session has a "Tip: press <leader>tF or
--      :TaskFeedback last-error" suffix appended to the notify message.
--      Subsequent ERRORs do not.
--   2. :TaskFeedback last-error opens the form prefilled with the most
--      recent ERROR's message in the "What happened?" section.
--   3. The global keymap <leader>tF is registered when feedback_key is
--      a string; not registered when feedback_key is false.

local function reset()
  package.loaded["taskwarrior"]          = nil
  package.loaded["taskwarrior.config"]   = nil
  package.loaded["taskwarrior.notify"]   = nil
  package.loaded["taskwarrior.feedback"] = nil
end

local function find_buf_by_name(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find(name, 1, true) then return b end
  end
  return nil
end

describe("taskwarrior.feedback — error hint append", function()
  local notifications, original_notify

  before_each(function()
    reset()
    notifications = {}
    original_notify = vim.notify
    vim.notify = function(msg, level, _opts)
      table.insert(notifications, { msg = tostring(msg), level = level })
    end
    require("taskwarrior").setup({})
  end)

  after_each(function() vim.notify = original_notify end)

  local function find_error_with_hint()
    for _, n in ipairs(notifications) do
      if n.level == vim.log.levels.ERROR
        and n.msg:lower():match("tip:")
        and n.msg:match("[Tt]ask[Ff]eedback") then
        return n
      end
    end
    return nil
  end

  it("first ERROR through notify.lua has the hint appended", function()
    local notify = require("taskwarrior.notify")
    notify("error", "taskwarrior.nvim: render failed", vim.log.levels.ERROR)
    local hit = find_error_with_hint()
    assert.is_not_nil(hit, "expected ERROR notify to include a Tip suffix; got "
      .. vim.inspect(notifications))
    assert.is_truthy(hit.msg:match("render failed"),
      "the original error message must still be present in the appended notify")
  end)

  it("subsequent ERRORs in the same session do NOT repeat the hint", function()
    local notify = require("taskwarrior.notify")
    notify("error", "first boom",  vim.log.levels.ERROR)
    notify("error", "second boom", vim.log.levels.ERROR)
    notify("error", "third boom",  vim.log.levels.ERROR)
    local count = 0
    for _, n in ipairs(notifications) do
      if n.level == vim.log.levels.ERROR and n.msg:lower():match("tip:") then
        count = count + 1
      end
    end
    assert.equals(1, count,
      "expected exactly 1 hint across multiple ERRORs; got " .. count)
  end)

  it("WARN does NOT trigger the hint (only ERROR)", function()
    local notify = require("taskwarrior.notify")
    notify("warn", "minor warning", vim.log.levels.WARN)
    notify("error", "boom",         vim.log.levels.ERROR)
    -- Only the ERROR (not the WARN) should have the hint.
    local hint_warn, hint_err = false, false
    for _, n in ipairs(notifications) do
      if n.msg:lower():match("tip:") then
        if n.level == vim.log.levels.WARN  then hint_warn = true end
        if n.level == vim.log.levels.ERROR then hint_err  = true end
      end
    end
    assert.is_false(hint_warn, "WARN should not get the hint")
    assert.is_true(hint_err,   "ERROR should get the hint")
  end)

  it("hint is suppressed when feedback.hint_on_error = false", function()
    reset()
    notifications = {}
    require("taskwarrior").setup({ feedback = { hint_on_error = false } })
    local notify = require("taskwarrior.notify")
    notify("error", "boom", vim.log.levels.ERROR)
    for _, n in ipairs(notifications) do
      assert.is_falsy(n.msg:lower():match("tip:"),
        "no Tip suffix when hint_on_error=false; got: " .. n.msg)
    end
  end)
end)

describe("taskwarrior.feedback last-error subcommand", function()
  before_each(function()
    reset()
    require("taskwarrior").setup({})
  end)

  after_each(function()
    local fb = find_buf_by_name("taskwarrior.nvim Feedback")
    if fb then pcall(vim.api.nvim_buf_delete, fb, { force = true }) end
  end)

  it("M.last_error() opens the form with the most recent ERROR prefilled", function()
    local notify   = require("taskwarrior.notify")
    local feedback = require("taskwarrior.feedback")
    notify("error", "OLD error",       vim.log.levels.ERROR)
    notify("warn",  "intervening warn", vim.log.levels.WARN)
    notify("error", "RECENT error",    vim.log.levels.ERROR)

    feedback.last_error()
    local buf = find_buf_by_name("taskwarrior.nvim Feedback")
    assert.is_not_nil(buf, "feedback buffer should open from last_error()")

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local content = table.concat(lines, "\n")
    -- The most-recent ERROR should be in the prefill, not the older one.
    assert.is_truthy(content:find("RECENT error", 1, true),
      "most-recent ERROR should be prefilled into form; lines: " .. content)
  end)

  it("M.last_error() with no captured ERROR opens the form with a placeholder", function()
    -- No notifications fired yet — the ring buffer is empty.
    local feedback = require("taskwarrior.feedback")
    feedback.last_error()
    local buf = find_buf_by_name("taskwarrior.nvim Feedback")
    assert.is_not_nil(buf, "form should open even when there's no last error")
  end)
end)

describe("taskwarrior.feedback global keymap", function()
  before_each(function()
    reset()
    -- Wipe any prior <leader>tF binding from a previous test.
    pcall(vim.keymap.del, "n", "<leader>tF")
  end)

  after_each(function()
    pcall(vim.keymap.del, "n", "<leader>tF")
  end)

  -- Searching by lhs is fragile — `<leader>` resolves to whatever
  -- mapleader was at registration time (default `\`, but test env may
  -- differ). The plugin's keymap descriptions are unique enough to
  -- identify reliably.
  local function find_by_desc(pattern)
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.desc and m.desc:find(pattern) then return m end
    end
    return nil
  end

  it("default config registers a normal-mode keymap for the feedback flow", function()
    require("taskwarrior").setup({})
    local hit = find_by_desc("Report a bug")
    assert.is_not_nil(hit,
      "expected a normal-mode binding with desc matching 'Report a bug'; "
        .. "got " .. tostring(#vim.api.nvim_get_keymap("n")) .. " entries")
  end)

  it("feedback = { feedback_key = false } disables the global keymap", function()
    require("taskwarrior").setup({ feedback = { feedback_key = false } })
    assert.is_nil(find_by_desc("Report a bug"),
      "feedback_key = false must skip keymap registration")
  end)
end)
