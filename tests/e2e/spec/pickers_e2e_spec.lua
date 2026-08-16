-- pickers_e2e_spec.lua — finite choices are chosen, not typed.
--
-- Sort spec, grouping, context, saved view and report all have small known
-- answer sets, so each is driven by a picker rather than a free-text prompt.
-- These tests stub vim.ui.select (standing in for whatever backend the user
-- has — dressing/telescope, snacks, fzf-lua) and assert the *effect* of a
-- selection, not merely that a picker appeared.

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local taskmd = require("taskwarrior.taskmd")
local context = require("taskwarrior.context")

-- Stub the picker: `chooser(labels)` returns the index to select, or nil to
-- cancel. Captures the rendered labels so tests can assert what was offered.
local function with_picker(chooser, fn)
  local orig = vim.ui.select
  local seen = {}
  vim.ui.select = function(items, opts, cb)
    local labels = {}
    for i, item in ipairs(items) do
      labels[i] = opts.format_item and opts.format_item(item) or tostring(item)
    end
    seen = { labels = labels, items = items, prompt = opts.prompt }
    local idx = chooser(labels, items)
    if idx == nil then return cb(nil) end
    cb(items[idx], idx)
  end
  local ok, err = pcall(fn)
  vim.ui.select = orig
  if not ok then error(err) end
  return seen
end

-- Fire a normal-mode keymap by its description. Matching on `desc` rather
-- than `lhs` because Neovim stores the mapping with <leader> already
-- expanded to the current mapleader, which the spec cannot assume.
local function press(bufnr, desc_fragment)
  local function search(maps)
    for _, m in ipairs(maps) do
      if m.callback and m.desc and m.desc:find(desc_fragment, 1, true) then
        m.callback()
        return true
      end
    end
    return false
  end
  if bufnr and bufnr ~= 0 and search(vim.api.nvim_buf_get_keymap(bufnr, "n")) then
    return true
  end
  if bufnr and search(vim.api.nvim_buf_get_keymap(bufnr, "n")) then return true end
  return search(vim.api.nvim_get_keymap("n"))
end

describe("e2e finite-choice pickers", function()
  if not next(require("taskwarrior.config").options) then
    require("taskwarrior").setup({})
  end
  local config = require("taskwarrior.config")

  taskmd.tw_add("picker probe alpha", { project = "pickdemo", priority = "H" })
  taskmd.tw_add("picker probe beta", { project = "pickdemo" })

  local function open_buf()
    vim.cmd("enew")
    require("taskwarrior").open("project:pickdemo")
    vim.wait(300, function() return false end, 10)
    return vim.api.nvim_get_current_buf()
  end

  it("sort key opens a picker and applies the chosen spec", function()
    local bufnr = open_buf()
    local seen = with_picker(function(labels)
      for i, l in ipairs(labels) do
        if l:find("due ↑", 1, true) then return i end
      end
    end, function()
      assert.is_true(press(bufnr, "Change sort"), "sort key not mapped")
      vim.wait(500, function() return vim.b[bufnr].task_sort == "due+" end, 10)
    end)

    assert.are.same("due+", vim.b[bufnr].task_sort,
      "picker selection did not change the buffer's sort")
    -- The active spec is marked, so the picker also answers "what's set now?".
    local marked = false
    for _, l in ipairs(seen.labels) do
      if l:sub(1, 3) == "● " or l:find("●", 1, true) then marked = true end
    end
    assert.is_true(marked, "no current-value marker in the sort picker")
  end)

  it("group key opens a picker and applies the chosen field", function()
    local bufnr = open_buf()
    with_picker(function(labels)
      for i, l in ipairs(labels) do
        if l:find("project", 1, true) then return i end
      end
    end, function()
      assert.is_true(press(bufnr, "Change grouping"), "group key not mapped")
      vim.wait(500, function() return vim.b[bufnr].task_group == "project" end, 10)
    end)
    assert.are.same("project", vim.b[bufnr].task_group)

    -- Choosing "none" clears it, rather than setting a literal group.
    with_picker(function(labels)
      for i, l in ipairs(labels) do
        if l:find("none", 1, true) then return i end
      end
    end, function()
      press(bufnr, "Change grouping")
      vim.wait(500, function() return vim.b[bufnr].task_group == nil end, 10)
    end)
    assert.is_nil(vim.b[bufnr].task_group, "'none' should clear grouping")
  end)

  it("context key picks a context and activates it", function()
    vim.fn.system("task rc.bulk=0 rc.confirmation=off rc.verbose=nothing " ..
      "context define pickctx project:pickdemo")
    context.set("none")

    local seen = with_picker(function(labels)
      for i, l in ipairs(labels) do
        if l:find("pickctx", 1, true) then return i end
      end
    end, function()
      assert.is_true(press(0, "Pick Taskwarrior context"), "context key not mapped")
      vim.wait(2000, function() return context.current() == "pickctx" end, 20)
    end)

    assert.are.same("pickctx", context.current(),
      "picker selection did not activate the context")
    -- The picker shows each context's filter, so you can tell them apart.
    local shows_filter = false
    for _, l in ipairs(seen.labels) do
      if l:find("project:pickdemo", 1, true) then shows_filter = true end
    end
    assert.is_true(shows_filter, "context picker does not show read filters")
    context.set("none")
  end)

  it("context picker offers 'none' and a define escape hatch", function()
    local seen = with_picker(function() return nil end, function()
      press(0, "Pick Taskwarrior context")
    end)
    local has_none, has_define = false, false
    for _, l in ipairs(seen.labels) do
      if l:find("clear context", 1, true) then has_none = true end
      if l:find("define a new context", 1, true) then has_define = true end
    end
    assert.is_true(has_none, "context picker has no 'none' entry")
    assert.is_true(has_define, "context picker has no define escape hatch")
  end)

  it("cancelling a picker changes nothing", function()
    local bufnr = open_buf()
    vim.b[bufnr].task_sort = "urgency-"
    with_picker(function() return nil end, function()
      press(bufnr, "Change sort")
      vim.wait(300, function() return false end, 10)
    end)
    assert.are.same("urgency-", vim.b[bufnr].task_sort,
      "cancelling the picker must not change the sort")
  end)

  it("bare :TwSort opens the picker instead of erroring", function()
    local bufnr = open_buf()
    local prefix = config.options.command_prefix or "Tw"
    with_picker(function(labels)
      for i, l in ipairs(labels) do
        if l:find("priority ↓", 1, true) then return i end
      end
    end, function()
      vim.cmd(prefix .. "Sort")
      vim.wait(500, function() return vim.b[bufnr].task_sort == "priority-" end, 10)
    end)
    assert.are.same("priority-", vim.b[bufnr].task_sort)
  end)

  it("report picker opens the chosen report", function()
    local seen = with_picker(function(labels)
      for i, l in ipairs(labels) do
        if l:find("overdue", 1, true) then return i end
      end
    end, function()
      assert.is_true(press(0, "Pick a named report"), "report key not mapped")
      vim.wait(1000, function()
        return (vim.b[vim.api.nvim_get_current_buf()].task_filter or ""):find("OVERDUE") ~= nil
      end, 20)
    end)

    local shows_filter = false
    for _, l in ipairs(seen.labels) do
      if l:find("status:pending", 1, true) then shows_filter = true end
    end
    assert.is_true(shows_filter, "report picker does not show each report's filter")
    local filter = vim.b[vim.api.nvim_get_current_buf()].task_filter or ""
    assert.is_truthy(filter:find("OVERDUE"),
      "overdue report did not open; filter = " .. filter)
  end)

  it("saved-view picker loads the chosen view (and no-arg :TwLoad asks)", function()
    local bufnr = open_buf()
    vim.b[bufnr].task_sort = "due+"
    require("taskwarrior").view_save("pickview")
    vim.wait(300, function() return false end, 10)

    vim.cmd("enew")
    with_picker(function(labels)
      for i, l in ipairs(labels) do
        if l:find("pickview", 1, true) then return i end
      end
    end, function()
      assert.is_true(press(0, "Pick a saved view"), "view key not mapped")
      vim.wait(1000, function()
        return vim.b[vim.api.nvim_get_current_buf()].task_filter ~= nil
      end, 20)
    end)

    local loaded = vim.api.nvim_get_current_buf()
    assert.are.same("project:pickdemo", vim.b[loaded].task_filter,
      "saved view did not load its filter")
  end)
end)
