-- context_e2e_spec.lua — Taskwarrior context support (tw c12b4cbd), driven
-- against the live task CLI seeded by tests/e2e/run.sh.
--
-- TW 3.x applies contexts to reports but NOT to `export`, so the plugin
-- injects the active context's read filter into its render path. The
-- injected tokens are part of the rendered header, which is what keeps the
-- save path honest — the last test here is the safety property that saving
-- a context-narrowed buffer must never touch the tasks the context hides.

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local taskmd = require("taskwarrior.taskmd")
local context = require("taskwarrior.context")

local function run_task(args)
  return vim.fn.system("task rc.bulk=0 rc.confirmation=off rc.verbose=nothing " .. args)
end

describe("e2e Taskwarrior contexts (tw c12b4cbd)", function()
  if not next(require("taskwarrior.config").options) then
    require("taskwarrior").setup({})
  end
  run_task("context define ctxwork project:ctxdemo")
  local in_uuid = taskmd.tw_add("inside the context", { project = "ctxdemo" })
  local out_uuid = taskmd.tw_add("outside the context", { project = "ctxother" })
  assert(in_uuid ~= "" and out_uuid ~= "")

  before_each(function()
    context.set("none")
  end)

  after_each(function()
    context.set("none")
  end)

  it("set/current/list/read_filter round-trip", function()
    assert.is_nil(context.current())
    context.set("ctxwork")
    assert.are.same("ctxwork", context.current())
    assert.are.same("project:ctxdemo", context.read_filter())
    local names = context.list()
    local found = false
    for _, n in ipairs(names) do if n == "ctxwork" then found = true end end
    assert.is_true(found, "ctxwork missing from context.list(): " .. vim.inspect(names))
    context.set("none")
    assert.is_nil(context.current())
  end)

  it("task buffer honors the active context's read filter", function()
    context.set("ctxwork")
    vim.cmd("enew")
    require("taskwarrior").open("")
    vim.wait(200, function() return false end, 10)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(text:find(in_uuid:sub(1, 8), 1, true),
      "context task missing from buffer")
    assert.is_nil(text:find(out_uuid:sub(1, 8), 1, true),
      "task outside the context leaked into the buffer")
  end)

  it("uuid-targeted filters are never context-narrowed", function()
    context.set("ctxwork")
    vim.cmd("enew")
    require("taskwarrior").open("uuid:" .. out_uuid)
    vim.wait(200, function() return false end, 10)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(text:find(out_uuid:sub(1, 8), 1, true),
      "uuid-filtered buffer came up empty under an active context")
  end)

  it("saving a context-narrowed buffer does not touch hidden tasks", function()
    context.set("ctxwork")
    vim.cmd("enew")
    require("taskwarrior").open("")
    vim.wait(200, function() return false end, 10)
    local bufnr = vim.api.nvim_get_current_buf()

    -- Edit the in-context task's description, then save with auto-accept.
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:find(in_uuid:sub(1, 8), 1, true) then
        lines[i] = line:gsub("inside the context", "inside the context edited")
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    local orig_select = vim.ui.select
    vim.ui.select = function(items, _, cb) cb(items[1], 1) end
    vim.cmd("silent write")
    vim.wait(3000, function()
      local t = taskmd.shell_export("uuid:" .. in_uuid)[1]
      return t and t.description == "inside the context edited"
    end, 20)
    vim.ui.select = orig_select

    local hidden = taskmd.shell_export("uuid:" .. out_uuid)[1]
    assert.is_truthy(hidden, "hidden task vanished entirely")
    assert.are.same("pending", hidden.status,
      "task hidden by the context was mutated by the save")
    local edited = taskmd.shell_export("uuid:" .. in_uuid)[1]
    assert.are.same("inside the context edited", edited.description)
  end)

  it(":TwContext command is registered with completion", function()
    local prefix = require("taskwarrior.config").options.command_prefix or "Tw"
    local cmds = vim.api.nvim_get_commands({})
    assert.is_truthy(cmds[prefix .. "Context"], ":" .. prefix .. "Context not registered")
    vim.cmd(prefix .. "Context ctxwork")
    vim.wait(200, function() return context.current() == "ctxwork" end, 10)
    assert.are.same("ctxwork", context.current())
    vim.cmd(prefix .. "Context none")
    vim.wait(200, function() return context.current() == nil end, 10)
    assert.is_nil(context.current())
  end)

  it("bare :TwContext clears the active context", function()
    local prefix = require("taskwarrior.config").options.command_prefix or "Tw"
    context.set("ctxwork")
    assert.are.same("ctxwork", context.current())
    vim.cmd(prefix .. "Context")
    vim.wait(500, function() return context.current() == nil end, 10)
    assert.is_nil(context.current(), "bare :TwContext did not clear the context")
  end)

  it("define creates a context and delete removes it", function()
    local name = ("ctxmade%d"):format(math.random(1, 1e6))
    -- define offers to activate; decline so this test only checks definition.
    local orig_select = vim.ui.select
    vim.ui.select = function(_, _, cb) cb("Leave inactive") end
    context.define(name, "project:ctxdemo or +ctx-hyphen-tag")
    vim.wait(2000, function()
      return context.read_filter(name) ~= nil
    end, 20)
    vim.ui.select = orig_select

    assert.are.same("project:ctxdemo or +ctx-hyphen-tag", context.read_filter(name),
      "context filter was not stored verbatim")
    local names = context.list()
    assert.is_true(vim.tbl_contains(names, name),
      "defined context missing from list: " .. vim.inspect(names))

    -- It actually works as a context.
    context.set(name)
    assert.are.same(name, context.current())
    context.set("none")

    context.delete(name)
    vim.wait(2000, function() return context.read_filter(name) == nil end, 20)
    assert.is_nil(context.read_filter(name), "context was not deleted")
    assert.is_false(vim.tbl_contains(context.list(), name),
      "deleted context still listed")
  end)

  it("define refuses the reserved name 'none'", function()
    local before = context.list()
    -- The refusal is an intentional ERROR-level notify. Captured rather than
    -- allowed through: an ERROR notify in headless Neovim writes to stderr
    -- and makes the process exit non-zero, which would fail the suite for a
    -- message the test is specifically asserting we DO emit.
    local messages = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, _lvl, _o) messages[#messages + 1] = tostring(msg) end
    context.define("none", "project:whatever")
    vim.wait(300, function() return false end, 10)
    vim.notify = orig_notify

    assert.are.same(#before, #context.list(),
      "defining a context named 'none' should be refused")
    local refused = false
    for _, m in ipairs(messages) do
      if m:find("reserved", 1, true) then refused = true end
    end
    assert.is_true(refused,
      "expected an explanatory refusal; got: " .. vim.inspect(messages))
  end)
end)
