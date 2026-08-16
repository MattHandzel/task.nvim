-- capture_rich_e2e_spec.lua — the roomier, colored capture form (tw 14d722e8).
--
-- Two properties, both observed rather than asserted-by-existence:
--   * lines below the first become real Taskwarrior annotations on save
--     (verified via `task export`), and capture_annotations = false opts out
--   * fields typed into the capture buffer get highlight extmarks — the
--     specific groups for known fields, the neutral TaskField group for
--     UDAs, and config.field_colors overrides on top

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local taskmd = require("taskwarrior.taskmd")

local function open_capture()
  require("taskwarrior").capture()
  vim.wait(100, function() return false end, 10)
  return vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
end

local function press_enter(buf)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "i")) do
    if m.lhs == "<CR>" and m.callback then
      m.callback()
      return true
    end
  end
  return false
end

-- Highlight groups present on a line, keyed by the text they cover.
local function highlights_on(buf, line_nr)
  require("taskwarrior.buffer").update_highlights(buf)
  local line = vim.api.nvim_buf_get_lines(buf, line_nr, line_nr + 1, false)[1] or ""
  local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { line_nr, 0 },
    { line_nr, -1 }, { details = true })
  local out = {}
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    if d.hl_group and d.end_col then
      out[line:sub(m[3] + 1, d.end_col)] = d.hl_group
    end
  end
  return out
end

describe("e2e rich capture (tw 14d722e8)", function()
  if not next(require("taskwarrior.config").options) then
    require("taskwarrior").setup({})
  end
  local config = require("taskwarrior.config")

  it("extra lines become annotations on the created task", function()
    local buf, win = open_capture()
    local desc = ("annotated capture %d"):format(math.random(1, 1e9))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      desc .. " project:annotest",
      "first annotation line",
      "",
      "second annotation line",
    })

    assert.is_true(press_enter(buf))
    vim.wait(5000, function()
      local t = (taskmd.shell_export("project:annotest") or {})[1]
      return t and t.annotations and #t.annotations == 2
    end, 20)
    pcall(vim.api.nvim_win_close, win, true)

    local tasks = taskmd.shell_export("project:annotest") or {}
    local stored
    for _, t in ipairs(tasks) do
      if t.description == desc then stored = t end
    end
    assert.is_truthy(stored, "captured task not found")
    local texts = {}
    for _, a in ipairs(stored.annotations or {}) do
      texts[#texts + 1] = a.description
    end
    table.sort(texts)
    assert.are.same({ "first annotation line", "second annotation line" }, texts,
      "extra capture lines did not become annotations")
  end)

  it("capture_annotations = false ignores the extra lines", function()
    local orig = config.options.capture_annotations
    config.options.capture_annotations = false

    local buf, win = open_capture()
    local desc = ("no annotations %d"):format(math.random(1, 1e9))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      desc .. " project:noannotest",
      "this line should be dropped",
    })
    assert.is_true(press_enter(buf))
    vim.wait(5000, function()
      local t = (taskmd.shell_export("project:noannotest") or {})[1]
      return t ~= nil
    end, 20)
    vim.wait(300, function() return false end, 10)
    config.options.capture_annotations = orig
    pcall(vim.api.nvim_win_close, win, true)

    local stored
    for _, t in ipairs(taskmd.shell_export("project:noannotest") or {}) do
      if t.description == desc then stored = t end
    end
    assert.is_truthy(stored, "captured task not found")
    assert.are.same(0, #(stored.annotations or {}),
      "annotations were created despite capture_annotations = false")
  end)

  it("colors known fields, tags, and UDAs in the capture buffer", function()
    local buf, win = open_capture()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "buy milk project:home priority:H +errand-run utility:20",
    })
    local hls = highlights_on(buf, 0)
    pcall(vim.api.nvim_win_close, win, true)

    assert.are.same("TaskProject", hls["project:home"],
      "project: not colored in capture buffer: " .. vim.inspect(hls))
    assert.are.same("TaskPriorityH", hls["priority:H"],
      "priority: not colored: " .. vim.inspect(hls))
    assert.are.same("TaskTag", hls["+errand-run"],
      "hyphenated tag not colored: " .. vim.inspect(hls))
    assert.are.same("TaskField", hls["utility:20"],
      "UDA field not colored with the neutral group: " .. vim.inspect(hls))
  end)

  it("honors config.field_colors overrides", function()
    local orig = config.options.field_colors
    config.options.field_colors = { utility = "ErrorMsg" }

    local buf, win = open_capture()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "task utility:20" })
    local hls = highlights_on(buf, 0)
    config.options.field_colors = orig
    pcall(vim.api.nvim_win_close, win, true)

    assert.are.same("ErrorMsg", hls["utility:20"],
      "field_colors override not applied: " .. vim.inspect(hls))
  end)

  it("does not color clock times or URLs as fields", function()
    local buf, win = open_capture()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "standup at 09:30 see https://x.dev" })
    local hls = highlights_on(buf, 0)
    pcall(vim.api.nvim_win_close, win, true)

    for text, group in pairs(hls) do
      assert.is_nil(text:match("^09:30"),
        "clock time was colored as a field (" .. group .. ")")
      assert.is_nil(text:match("^https:"),
        "URL was colored as a field (" .. group .. ")")
    end
  end)
end)
