-- tests/lua/spec/feedback_buffer_context_spec.lua
--
-- The `g?` shortcut inside :Task buffers — opens :TaskFeedback and
-- prefills the form's "Anything else?" section with sanitized buffer
-- context so users can report rendering/layout bugs without manually
-- copying anything.
--
-- Sanitization rule (per design): Taskwarrior structural tokens are
-- preserved verbatim, free-form description text has every alphanumeric
-- replaced with `a`. The user can review/redact before sending. See
-- lua/taskwarrior/feedback/privacy.lua + spec
-- tests/lua/spec/feedback_privacy_spec.lua for the scrubber rules.

local function reset()
  package.loaded["taskwarrior"]                  = nil
  package.loaded["taskwarrior.config"]           = nil
  package.loaded["taskwarrior.notify"]           = nil
  package.loaded["taskwarrior.feedback"]         = nil
  package.loaded["taskwarrior.feedback.privacy"] = nil
  package.loaded["taskwarrior.feedback.context"] = nil
end

local function find_buf_by_name(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find(name, 1, true) then return b end
  end
  return nil
end

describe("taskwarrior.feedback.context — capture sanitized :Task buffer context", function()
  local context

  before_each(function()
    reset()
    require("taskwarrior").setup({})
    context = require("taskwarrior.feedback.context")
  end)

  describe("capture(bufnr, cursor_lnum)", function()
    it("returns a struct with filter, sort, group, and scrubbed lines", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "## Project Work",
        "- [ ] Fix login bug project:Work priority:H +urgent",
        "- [ ] Pay rent due:2026-04-01",
        "- [ ] Call mom",
      })
      -- The capture function reads buffer-local vars set by the renderer
      -- to know the current filter/sort/group. Stub them.
      vim.b[buf].taskwarrior_filter = "status:pending"
      vim.b[buf].taskwarrior_sort   = "urgency-"
      vim.b[buf].taskwarrior_group  = "project"

      local snap = context.capture(buf, 2)
      assert.equals("status:pending", snap.filter)
      assert.equals("urgency-",       snap.sort)
      assert.equals("project",        snap.group)
      assert.is_table(snap.lines)
      assert.is_true(#snap.lines >= 1, "should capture at least the cursor line")
    end)

    it("scrubs description content but preserves Taskwarrior tokens", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "- [ ] Sensitive description with email user@example.com project:Work +urgent",
      })

      local snap = context.capture(buf, 1)
      local out = snap.lines[1]
      -- Structural tokens MUST be preserved verbatim.
      assert.is_truthy(out:find("project:Work", 1, true),
        "project:Work must be preserved; got: " .. out)
      assert.is_truthy(out:find("+urgent", 1, true),
        "+urgent tag must be preserved; got: " .. out)
      -- The free-form description must NOT be present verbatim.
      assert.is_nil(out:find("Sensitive", 1, true),
        "free-form description must be scrubbed; got: " .. out)
      assert.is_nil(out:find("user@example.com", 1, true),
        "email content must be scrubbed; got: " .. out)
    end)

    it("captures a window of lines around the cursor (not the whole buffer)", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local lines = {}
      for i = 1, 100 do table.insert(lines, "- [ ] Task number " .. i) end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      local snap = context.capture(buf, 50)
      -- Per design: max ~25 lines around cursor = ~50 total. Allow some
      -- slack but assert it's not "all 100 lines".
      assert.is_true(#snap.lines <= 60,
        "context window should not exceed ~50 lines; got " .. #snap.lines)
      assert.is_true(#snap.lines >= 10,
        "context window should include surrounding rows; got " .. #snap.lines)
    end)

    it("missing buffer-local vars default to '<unknown>'", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- [ ] Foo" })

      local snap = context.capture(buf, 1)
      assert.equals("<unknown>", snap.filter)
      assert.equals("<unknown>", snap.sort)
      assert.equals("<unknown>", snap.group)
    end)
  end)

  describe("format(snap) → markdown block", function()
    it("renders a fenced markdown block for embedding in the form", function()
      local snap = {
        filter = "status:pending",
        sort   = "urgency-",
        group  = "project",
        lines  = { "- [ ] aaa", "- [ ] aaaaaa" },
      }
      local md = context.format(snap)
      assert.is_string(md)
      assert.is_truthy(md:find("filter:", 1, true), "should mention filter:")
      assert.is_truthy(md:find("status:pending", 1, true))
      assert.is_truthy(md:find("```", 1, true), "should fence the buffer snippet")
      assert.is_truthy(md:find("- %[ %] aaa"), "scrubbed lines should appear in fence")
    end)
  end)
end)

describe("`g?` keymap inside :Task buffers", function()
  before_each(function()
    reset()
    require("taskwarrior").setup({})
  end)

  after_each(function()
    local fb = find_buf_by_name("taskwarrior.nvim Feedback")
    if fb then pcall(vim.api.nvim_buf_delete, fb, { force = true }) end
  end)

  it("setup_buf_keymaps(bufnr) registers buffer-local g?", function()
    local buf = vim.api.nvim_create_buf(false, true)
    require("taskwarrior.buffer").setup_buf_keymaps(buf)
    -- Search for our binding by its description rather than lhs.
    local maps = vim.api.nvim_buf_get_keymap(buf, "n")
    local found = nil
    for _, m in ipairs(maps) do
      if m.lhs == "g?" then found = m; break end
    end
    assert.is_not_nil(found,
      "expected g? to be registered as a buffer-local normal-mode keymap; "
        .. "got " .. tostring(#maps) .. " entries")
  end)
end)
