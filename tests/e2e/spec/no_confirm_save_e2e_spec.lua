-- no_confirm_save_e2e_spec.lua — the configurable save popup (tw fca82462).
--
-- With setup({ confirm = false }) the Apply/Cancel picker must never appear:
-- :w applies immediately, the summary notification names what happened and
-- points at :TwUndo, and :TwUndo actually reverts the mutation in
-- Taskwarrior. Driven against the live task CLI seeded by tests/e2e/run.sh.

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local taskmd = require("taskwarrior.taskmd")

describe("e2e no-confirm save (tw fca82462)", function()
  local orig_confirm

  before_each(function()
    local config = require("taskwarrior.config")
    if not next(config.options) then require("taskwarrior").setup({}) end
    orig_confirm = config.options.confirm
    config.options.confirm = false
  end)

  after_each(function()
    require("taskwarrior.config").options.confirm = orig_confirm
  end)

  it(":w applies without a picker, notifies summary + undo hint, undo reverts", function()
    local marker = ("noconfirm %d"):format(math.random(1, 1e9))
    local uuid = taskmd.tw_add(marker, { project = "noconfirmtest" })
    assert.is_true(uuid ~= "")

    vim.cmd("enew")
    require("taskwarrior").open("uuid:" .. uuid)
    vim.wait(200, function() return false end, 10)
    local bufnr = vim.api.nvim_get_current_buf()

    -- Edit the description in the buffer.
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:find(marker, 1, true) then
        lines[i] = line:gsub(vim.pesc(marker), marker .. " edited")
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    -- The picker must NOT be involved in this flow.
    local orig_select = vim.ui.select
    local select_called = false
    vim.ui.select = function(items, _, cb)
      select_called = true
      cb(nil)
    end

    local messages = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, ...) messages[#messages + 1] = tostring(msg) end

    vim.cmd("silent write")
    vim.wait(3000, function()
      local t = taskmd.shell_export("uuid:" .. uuid)[1]
      return t and t.description == marker .. " edited"
    end, 20)

    vim.notify = orig_notify
    assert.is_false(select_called,
      "confirm=false save still invoked vim.ui.select")

    local t = taskmd.shell_export("uuid:" .. uuid)[1]
    assert.are.same(marker .. " edited", t.description,
      "save did not apply the edit")

    local summary
    for _, m in ipairs(messages) do
      if m:find("Applied:", 1, true) then summary = m end
    end
    assert.is_truthy(summary, "no apply summary notification; got: "
      .. vim.inspect(messages))
    assert.is_truthy(summary:find("~1 modified", 1, true),
      "summary does not name the modify: " .. summary)
    assert.is_truthy(summary:find("Undo to revert", 1, true),
      "summary does not mention the undo path: " .. summary)

    -- :TwUndo (driven via apply.undo) reverts the modify.
    vim.ui.select = function(items, _, cb) cb("Undo", 1) end
    require("taskwarrior").undo()
    vim.wait(3000, function()
      local cur = taskmd.shell_export("uuid:" .. uuid)[1]
      return cur and cur.description == marker
    end, 20)
    vim.ui.select = orig_select

    local reverted = taskmd.shell_export("uuid:" .. uuid)[1]
    assert.are.same(marker, reverted.description,
      "undo did not revert the modify")
  end)

  it("confirm=true keeps the popup (control)", function()
    local marker = ("withconfirm %d"):format(math.random(1, 1e9))
    local uuid = taskmd.tw_add(marker, { project = "noconfirmtest" })
    require("taskwarrior.config").options.confirm = true

    vim.cmd("enew")
    require("taskwarrior").open("uuid:" .. uuid)
    vim.wait(200, function() return false end, 10)
    local bufnr = vim.api.nvim_get_current_buf()

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:find(marker, 1, true) then
        lines[i] = line:gsub(vim.pesc(marker), marker .. " edited")
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    local orig_select = vim.ui.select
    local select_called = false
    vim.ui.select = function(items, _, cb)
      select_called = true
      cb(nil) -- cancel
    end
    vim.cmd("silent write")
    vim.wait(1000, function() return select_called end, 20)
    vim.ui.select = orig_select

    assert.is_true(select_called, "confirm=true save never showed the picker")
    local t = taskmd.shell_export("uuid:" .. uuid)[1]
    assert.are.same(marker, t.description,
      "cancelled confirm save must not mutate the task")
  end)
end)
