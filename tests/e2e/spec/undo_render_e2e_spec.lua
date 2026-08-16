-- undo_render_e2e_spec.lua — `u` must not undo the render itself.
--
-- Populating a task buffer is not a user edit. When it was undoable, `u` in
-- a freshly opened :Tw reverted the population and left an empty buffer —
-- which the save path reads as "every task in this filter was removed" and
-- duly offers to mark them all done/deleted. Reported as: pressing u gives a
-- blank screen, a header read-only warning, and a prompt to delete
-- everything.
--
-- The important assertion is the last one: what a SAVE would do after `u`.
-- Line counts alone would not have caught the destructive part.

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local taskmd = require("taskwarrior.taskmd")

local function planned_actions(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmpfile = vim.fn.tempname()
  vim.fn.writefile(lines, tmpfile)
  local res = taskmd.apply({ file = tmpfile, dry_run = true, on_delete = "done" })
  vim.fn.delete(tmpfile)
  return res.actions or {}, res
end

describe("e2e undo does not revert the render", function()
  if not next(require("taskwarrior.config").options) then
    require("taskwarrior").setup({})
  end

  taskmd.tw_add("undo probe one", { project = "undorenderdemo" })
  taskmd.tw_add("undo probe two", { project = "undorenderdemo" })

  local function open()
    vim.cmd("enew")
    require("taskwarrior").open("project:undorenderdemo")
    vim.wait(300, function() return false end, 10)
    return vim.api.nvim_get_current_buf()
  end

  it("leaves the buffer intact when undoing a fresh open", function()
    local bufnr = open()
    local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.is_true(#before >= 3, "fixture did not render both tasks")

    vim.cmd("silent! undo")
    vim.wait(200, function() return false end, 10)

    local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.are.same(before, after,
      "`u` on a fresh buffer changed its contents — the render was undoable")
  end)

  it("keeps the buffer unmodified after undoing a fresh open", function()
    local bufnr = open()
    vim.cmd("silent! undo")
    vim.wait(200, function() return false end, 10)
    assert.is_false(vim.bo[bufnr].modified,
      "undo dirtied a buffer the user never edited")
  end)

  it("a save after undo would touch nothing — no mass delete", function()
    local bufnr = open()
    vim.cmd("silent! undo")
    vim.wait(200, function() return false end, 10)

    local actions = planned_actions(bufnr)
    assert.are.same(0, #actions,
      "saving after `u` would run " .. #actions ..
      " action(s) — undo must not stage a mass mutation: " .. vim.inspect(actions))
  end)

  it("still undoes the user's own edits", function()
    local bufnr = open()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local target
    for i, l in ipairs(lines) do
      if l:find("undo probe one", 1, true) then target = i end
    end
    assert.is_truthy(target, "probe task not rendered")

    -- A real, undoable user edit (not nvim_buf_set_lines, which the render
    -- path deliberately makes non-undoable).
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    vim.cmd("normal! AZZZEDIT")
    assert.is_truthy(
      (vim.api.nvim_buf_get_lines(bufnr, target - 1, target, false)[1] or ""):find("ZZZEDIT"),
      "test edit did not land")

    vim.cmd("silent! undo")
    vim.wait(200, function() return false end, 10)

    local restored = vim.api.nvim_buf_get_lines(bufnr, target - 1, target, false)[1] or ""
    assert.is_nil(restored:find("ZZZEDIT", 1, true),
      "user's own edit was not undone — undo is now too aggressive")
    assert.are.same(#lines, vim.api.nvim_buf_line_count(bufnr),
      "undoing a user edit collapsed the buffer")
  end)

  it("survives a refresh followed by undo", function()
    local bufnr = open()
    local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    require("taskwarrior.buffer").refresh_buf(bufnr)
    vim.wait(300, function() return false end, 10)
    vim.cmd("silent! undo")
    vim.wait(200, function() return false end, 10)

    local actions = planned_actions(bufnr)
    assert.are.same(0, #actions,
      "undo after a refresh staged " .. #actions .. " action(s)")
    assert.are.same(#before, vim.api.nvim_buf_line_count(bufnr),
      "undo after a refresh changed the buffer size")
  end)
end)
