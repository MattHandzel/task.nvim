-- table_view_e2e_spec.lua — :TwTable, the vit-style column view (tw 6e9f911d).
--
-- Asserts the rendered geometry (columns actually align, nothing overflows
-- the window width), that config.table_columns really drives the layout
-- including UDA and custom-format columns, and that the view's <CR> opens
-- the right task in an editable :Tw buffer.

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local taskmd = require("taskwarrior.taskmd")
local table_view = require("taskwarrior.table_view")

-- Split a rendered row on the 2-space left margin + single-space gutters is
-- ambiguous; instead assert alignment by comparing display columns of the
-- header cells against each row's cells at the same byte offsets.
local function display_width(s) return vim.fn.strdisplaywidth(s) end

describe("e2e :TwTable (tw 6e9f911d)", function()
  if not next(require("taskwarrior.config").options) then
    require("taskwarrior").setup({})
  end
  local config = require("taskwarrior.config")

  local uuid = taskmd.tw_add("table view target", {
    project = "tabledemo", priority = "H", tags = { "tbl-one", "tbl-two" },
  })
  assert(uuid ~= "")

  it("renders aligned rows that fit the window width", function()
    local tasks = taskmd.shell_export("project:tabledemo") or {}
    assert.is_true(#tasks > 0)
    local lines = table_view.build(tasks, { filter = "project:tabledemo", width = 100 })

    for i, line in ipairs(lines) do
      assert.is_true(display_width(line) <= 100,
        ("line %d overflows the 100-col budget (%d): %q")
          :format(i, display_width(line), line))
    end

    -- Header, separator, then one row per task.
    assert.is_truthy(lines[2]:find("Description", 1, true), "no Description header")
    assert.is_truthy(lines[3]:find("─", 1, true), "no separator row")
    local row
    for _, l in ipairs(lines) do
      if l:find("table view target", 1, true) then row = l end
    end
    assert.is_truthy(row, "task row missing:\n" .. table.concat(lines, "\n"))
    assert.is_truthy(row:find("tabledemo", 1, true), "project cell missing")
    assert.is_truthy(row:find("tbl%-one,tbl%-two"), "tags cell missing")

    -- Columns align: the description header and the description cell start
    -- at the same display column.
    local header = lines[2]
    local hdr_col = display_width(header:sub(1, header:find("Description", 1, true) - 1))
    local cell_col = display_width(row:sub(1, row:find("table view target", 1, true) - 1))
    assert.are.same(hdr_col, cell_col,
      "description column is not aligned with its header")
  end)

  it("honors config.table_columns including UDA and format columns", function()
    local orig = config.options.table_columns
    config.options.table_columns = {
      { field = "description", width = 20 },
      { field = "project", label = "Proj", width = 10 },
      { field = "tags", label = "Count", width = 6,
        format = function(v) return tostring(#(v or {})) end },
    }
    local tasks = taskmd.shell_export("project:tabledemo") or {}
    local lines = table_view.build(tasks, { filter = "project:tabledemo", width = 80 })
    config.options.table_columns = orig

    assert.is_truthy(lines[2]:find("Proj", 1, true), "custom label missing from header")
    assert.is_truthy(lines[2]:find("Count", 1, true), "format column missing from header")
    assert.is_nil(lines[2]:find("Urg", 1, true),
      "default columns leaked into a custom layout")

    local row
    for _, l in ipairs(lines) do
      if l:find("table view target", 1, true) then row = l end
    end
    assert.is_truthy(row, "task row missing under custom columns")
    -- The format function turned the tag list into its count.
    assert.is_truthy(row:find("2", 1, true), "format column did not render the count")
    assert.is_nil(row:find("tbl-one", 1, true),
      "raw tag value rendered despite a format function")
  end)

  it("truncates over-long cells with an ellipsis instead of overflowing", function()
    local long = taskmd.tw_add(("wordy "):rep(40) .. "end", { project = "tablewide" })
    local tasks = taskmd.shell_export("uuid:" .. long) or {}
    local lines = table_view.build(tasks, { filter = "uuid", width = 100 })
    for _, line in ipairs(lines) do
      assert.is_true(display_width(line) <= 100,
        ("long description overflowed: %d cols"):format(display_width(line)))
    end
    local row
    for _, l in ipairs(lines) do
      if l:find("wordy", 1, true) then row = l end
    end
    assert.is_truthy(row, "long-description row missing")
    assert.is_truthy(row:find("…", 1, true), "long cell was not ellipsized")
  end)

  it(":TwTable opens a view buffer and <CR> opens that task for editing", function()
    local prefix = config.options.command_prefix or "Tw"
    assert.is_truthy(vim.api.nvim_get_commands({})[prefix .. "Table"],
      ":" .. prefix .. "Table not registered")

    vim.cmd(prefix .. "Table project:tabledemo")
    vim.wait(500, function() return false end, 10)
    local view_buf = vim.api.nvim_get_current_buf()
    assert.are.same("taskwarrior_view", vim.bo[view_buf].filetype)
    assert.is_false(vim.bo[view_buf].modifiable, "table view should be read-only")

    -- Put the cursor on the task row, then fire <CR>.
    local lines = vim.api.nvim_buf_get_lines(view_buf, 0, -1, false)
    local row_nr
    for i, l in ipairs(lines) do
      if l:find("table view target", 1, true) then row_nr = i end
    end
    assert.is_truthy(row_nr, "task row not found in the opened view")
    vim.api.nvim_win_set_cursor(0, { row_nr, 0 })

    local cr
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(view_buf, "n")) do
      if m.lhs == "<CR>" and m.callback then cr = m.callback end
    end
    assert.is_truthy(cr, "<CR> keymap missing from the table view")
    cr()
    vim.wait(500, function()
      return vim.b[vim.api.nvim_get_current_buf()].task_filter ~= nil
    end, 10)

    local task_buf = vim.api.nvim_get_current_buf()
    assert.are.same("uuid:" .. uuid, vim.b[task_buf].task_filter,
      "<CR> did not open the task under the cursor")
    local text = table.concat(vim.api.nvim_buf_get_lines(task_buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("table view target", 1, true),
      "opened buffer does not contain the task")
  end)
end)
