-- buffer_layout_e2e_spec.lua — the task buffer starts at the top.
--
-- The taskmd header comment is metadata, not content: it must cost zero
-- screen rows, and the first task must be drawn on the window's top line
-- with the cursor already on it.
--
-- Asserting the extmark exists is NOT enough here — `conceal` blanks a row
-- but still occupies it, while `conceal_lines` (Neovim 0.11+) removes it.
-- The observable difference is `winline()`, so that is what's checked.

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local taskmd = require("taskwarrior.taskmd")
local buffer = require("taskwarrior.buffer")

local has_conceal_lines = pcall(function()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "x" })
  local ok = pcall(vim.api.nvim_buf_set_extmark, b,
    vim.api.nvim_create_namespace("probe"), 0, 0, { conceal_lines = "" })
  pcall(vim.api.nvim_buf_delete, b, { force = true })
  assert(ok)
end)

describe("e2e task buffer layout", function()
  if not next(require("taskwarrior.config").options) then
    require("taskwarrior").setup({})
  end

  local uuid = taskmd.tw_add("layout probe task", { project = "layoutdemo" })
  assert(uuid ~= "")

  it("renders no blank spacer between the header and the first task", function()
    local out = taskmd.render({ filter = { "project:layoutdemo" }, sort = "urgency-" })
    local lines = vim.split(out, "\n", { plain = true })
    assert.is_truthy(lines[1]:match("^<!%-%-.*taskmd"), "line 1 is not the header")
    assert.is_truthy(lines[2] and lines[2]:match("^%- %["),
      "line 2 should be the first task, got: " .. vim.inspect(lines[2]))
  end)

  it("puts the cursor on the first task, not the header", function()
    vim.cmd("enew")
    require("taskwarrior").open("project:layoutdemo")
    vim.wait(300, function() return false end, 10)

    local row = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
    assert.is_truthy(line:match("^%- %["),
      ("cursor landed on a non-task line (row %d): %q"):format(row, line))
    assert.is_truthy(line:find("layout probe task", 1, true),
      "cursor is not on the seeded task")
  end)

  it("draws the first task on the window's top screen row", function()
    if not has_conceal_lines then
      -- Neovim < 0.11 keeps a blank concealed row; the layout goal only
      -- applies where conceal_lines exists.
      return
    end
    vim.cmd("enew")
    require("taskwarrior").open("project:layoutdemo")
    vim.wait(300, function() return false end, 10)
    vim.cmd("normal! zt")

    assert.are.same(1, vim.fn.winline(),
      "first task is not on the top screen row — the header row still " ..
      "occupies space (winline = " .. vim.fn.winline() .. ")")
  end)

  it("cursor_to_first_task tolerates a buffer with no tasks", function()
    vim.cmd("enew")
    require("taskwarrior").open("project:definitely-no-such-project-here")
    vim.wait(300, function() return false end, 10)
    -- Must not error, and must not leave the cursor past the end.
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local count = vim.api.nvim_buf_line_count(0)
    assert.is_true(row >= 1 and row <= count,
      ("cursor row %d outside buffer of %d lines"):format(row, count))
  end)

  it("the float path also opens on the first task", function()
    vim.cmd("enew")
    require("taskwarrior.buffer").open_float("project:layoutdemo")
    vim.wait(300, function() return false end, 10)

    local row = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
    assert.is_truthy(line:match("^%- %["),
      ("float cursor landed on a non-task line (row %d): %q"):format(row, line))
    vim.cmd("close")
  end)
end)
