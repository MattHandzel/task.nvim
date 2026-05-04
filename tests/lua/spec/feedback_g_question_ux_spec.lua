-- tests/lua/spec/feedback_g_question_ux_spec.lua
--
-- Three UX additions to the g? flow inside :Task buffers:
--
--   1. context.capture takes opts { scrub = bool, radius = N }
--      so the user can choose between scrambled (default) or original.
--   2. context.format header indicates which mode was used.
--   3. feedback.open_with_context prepends a preamble explaining what
--      the form is — when a user hits g? for the first time they see
--      a clear "you're filing a bug report" header above the noise.
--
-- The g? keymap itself shows a vim.ui.select picker with three
-- choices (scrambled / original / no context) before opening the form.
-- That part is asserted in smoke_user_flows_spec via "fire g? for real".

local function reset()
  for k in pairs(package.loaded) do
    if k:match("^taskwarrior") then package.loaded[k] = nil end
  end
end

describe("feedback.context.capture — scrub option", function()
  local ctx
  before_each(function()
    reset()
    require("taskwarrior").setup({})
    ctx = require("taskwarrior.feedback.context")
  end)

  it("default behavior is scrubbed (backward compatible)", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "- [ ] Sensitive description project:Work +urgent",
    })
    local snap = ctx.capture(buf, 1)  -- no opts → defaults to scrubbed
    assert.equals(true, snap.scrubbed,
      "default capture should be scrubbed (snap.scrubbed = true)")
    assert.is_nil(snap.lines[1]:find("Sensitive", 1, true),
      "default capture should not contain unscrubbed text")
  end)

  it("scrub=false returns original lines verbatim", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "- [ ] Sensitive description project:Work +urgent",
    })
    local snap = ctx.capture(buf, 1, { scrub = false })
    assert.equals(false, snap.scrubbed,
      "scrub=false capture should mark snap.scrubbed = false")
    assert.is_truthy(snap.lines[1]:find("Sensitive description", 1, true),
      "scrub=false capture should preserve the original description; got: "
        .. snap.lines[1])
  end)

  it("radius option controls how many lines are captured", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, 50 do table.insert(lines, "- [ ] task " .. i) end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    local small = ctx.capture(buf, 25, { radius = 3 })
    assert.is_true(#small.lines <= 7,
      "radius=3 should give at most 7 lines (3+1+3); got " .. #small.lines)

    local big = ctx.capture(buf, 25, { radius = 20 })
    assert.is_true(#big.lines >= 15,
      "radius=20 should give substantially more lines; got " .. #big.lines)
  end)

  it("default radius is small enough to fit a typical URL", function()
    -- Per the URL-too-long fix: the user's previous default of 25 each
    -- side made every g? capture overflow GitHub's URL limit. Default
    -- should be small enough that the typical capture fits.
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, 50 do table.insert(lines, "- [ ] task " .. i) end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local snap = ctx.capture(buf, 25)
    assert.is_true(#snap.lines <= 20,
      "default capture should be modest in size (the user's report "
        .. "showed >25-line captures overflowing GitHub's URL limit); "
        .. "got " .. #snap.lines .. " lines")
  end)
end)

describe("feedback.context.format — header reflects mode", function()
  local ctx
  before_each(function()
    reset()
    ctx = require("taskwarrior.feedback.context")
  end)

  it("scrubbed snap → header says 'sanitized'", function()
    local md = ctx.format({
      filter = "x", sort = "y", group = "z",
      lines = { "- [ ] aaa" }, scrubbed = true,
    })
    assert.is_truthy(md:lower():match("sanitiz") or md:lower():match("scrambl"),
      "scrubbed format should advertise sanitization in the header; got:\n" .. md)
  end)

  it("non-scrubbed snap → header WARNS that descriptions are visible", function()
    local md = ctx.format({
      filter = "x", sort = "y", group = "z",
      lines = { "- [ ] real content here" }, scrubbed = false,
    })
    assert.is_truthy(md:lower():match("original")
                  or md:lower():match("not scrubbed")
                  or md:lower():match("descriptions visible"),
      "non-scrubbed format must clearly mark itself as containing original content; got:\n" .. md)
  end)
end)

describe("feedback.open_with_context — form preamble", function()
  local feedback
  before_each(function()
    reset()
    require("taskwarrior").setup({})
    feedback = require("taskwarrior.feedback")
    -- Wipe any lingering feedback buffer.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find("Feedback", 1, true) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end)

  it("opens the form with a preamble explaining what it is", function()
    feedback.open_with_context("scrubbed sample block")
    local buf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find("Feedback", 1, true) then
        buf = b; break
      end
    end
    assert.is_not_nil(buf, "feedback buffer not opened")
    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    -- Some kind of "you opened this via g?" / "this is the bug-report
    -- form" header. Match liberally — wording can change, but SOMETHING
    -- explanatory must precede the empty "What happened?" section.
    assert.is_truthy(content:lower():match("bug")
                  or content:lower():match("report")
                  or content:lower():match("g%?")
                  or content:lower():match("buffer"),
      "form should have a preamble explaining what it is when opened via g?; got:\n"
        .. content:sub(1, 600))
  end)
end)
