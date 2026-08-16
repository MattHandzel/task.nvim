-- hyphen_tag_e2e_spec.lua — end-to-end regression shield for hyphenated tag
-- names against a real Taskwarrior 3.x CLI (tw task 3b9dfcab).
--
-- TW3's expression parser mis-parses bare `+foo-bar` tokens (the hyphen is
-- read as subtraction). Before the fix:
--   * :TwFilter +ais-research-taste → "Cannot subtract from a Boolean value"
--     and the buffer silently rendered nothing
--   * capture `+foo-bar` → the tag landed inside the description text
--   * modify_tag / inbox "+tag" → exit 2, tag never applied
--
-- Each scenario here drives the plugin path and asserts the observable
-- Taskwarrior state, not just the absence of an error.

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local taskmd = require("taskwarrior.taskmd")

local function unique_hyphen_tag(prefix)
  return string.format("%s-hyphen-%d-%d", prefix, vim.fn.getpid(), math.random(1, 1e9))
end

describe("e2e hyphenated tags (tw 3b9dfcab)", function()
  it("shell_export matches a task filtered by +hyphen-tag", function()
    local tag = unique_hyphen_tag("filter")
    local uuid, ok = taskmd.tw_add("filter by hyphen tag", { tags = { tag } })
    assert.is_true(ok)
    assert.is_true(uuid ~= "")

    local tasks = taskmd.shell_export("+" .. tag)
    assert.is_table(tasks)
    assert.are.same(1, #tasks)
    assert.are.same(uuid, tasks[1].uuid)
    assert.are.same({ tag }, tasks[1].tags)
  end)

  it("shell_export excludes via -hyphen-tag", function()
    local tag = unique_hyphen_tag("excl")
    local uuid = taskmd.tw_add("excluded by hyphen tag", { tags = { tag } })
    local tasks = taskmd.shell_export("status:pending -" .. tag)
    assert.is_table(tasks)
    for _, t in ipairs(tasks) do
      assert.is_true(t.uuid ~= uuid, "task with excluded tag leaked through")
    end
  end)

  it("tw_add stores hyphenated tags as tags, not description text", function()
    local tag = unique_hyphen_tag("add")
    local uuid, ok = taskmd.tw_add("clean description", { tags = { tag, "plain" } })
    assert.is_true(ok)
    local t = taskmd.shell_export("uuid:" .. uuid)[1]
    assert.are.same("clean description", t.description)
    table.sort(t.tags)
    local expected = { "plain", tag }
    table.sort(expected)
    assert.are.same(expected, t.tags)
  end)

  it("tw_change_tag appends and removes a hyphenated tag", function()
    local base = unique_hyphen_tag("base")
    local extra = unique_hyphen_tag("extra")
    local uuid = taskmd.tw_add("tag delta target", { tags = { base } })

    assert.is_true(taskmd.tw_change_tag(uuid, extra))
    local t = taskmd.shell_export("uuid:" .. uuid)[1]
    table.sort(t.tags)
    local expected = { base, extra }
    table.sort(expected)
    assert.are.same(expected, t.tags)

    assert.is_true(taskmd.tw_change_tag(uuid, base, true))
    t = taskmd.shell_export("uuid:" .. uuid)[1]
    assert.are.same({ extra }, t.tags)
  end)

  it("task buffer opened with a +hyphen-tag filter renders the task", function()
    local tag = unique_hyphen_tag("buf")
    local uuid = taskmd.tw_add("visible in filtered buffer", { tags = { tag } })

    vim.cmd("enew")
    require("taskwarrior").open("+" .. tag)
    vim.wait(200, function() return false end, 10)

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local found = false
    for _, line in ipairs(lines) do
      if line:find(uuid:sub(1, 8), 1, true) then found = true end
    end
    assert.is_true(found, "filtered buffer did not render the tagged task:\n"
      .. table.concat(lines, "\n"))
  end)

  it("saving a buffer that drops one of two tags applies the removal", function()
    local keep = unique_hyphen_tag("keep")
    local drop = unique_hyphen_tag("drop")
    local uuid = taskmd.tw_add("partial tag removal", { tags = { keep, drop } })

    vim.cmd("enew")
    require("taskwarrior").open("uuid:" .. uuid)
    vim.wait(200, function() return false end, 10)
    local bufnr = vim.api.nvim_get_current_buf()

    -- Remove the `drop` tag from the rendered line, keep everything else.
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:find(uuid:sub(1, 8), 1, true) then
        lines[i] = line:gsub("%s*%+" .. vim.pesc(drop), "")
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    -- Non-interactive apply: auto-accept the confirm picker.
    local orig_select = vim.ui.select
    vim.ui.select = function(items, _, cb) cb(items[1], 1) end
    vim.cmd("silent write")
    vim.wait(2000, function()
      local t = taskmd.shell_export("uuid:" .. uuid)[1]
      return t and t.tags and #t.tags == 1
    end, 20)
    vim.ui.select = orig_select

    local t = taskmd.shell_export("uuid:" .. uuid)[1]
    assert.are.same({ keep }, t.tags,
      "expected only the kept tag after save-applied removal")
  end)
end)
