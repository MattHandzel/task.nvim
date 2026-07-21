-- Regression specs for GitHub issues #3, #4, #5.
--
-- #5 — :Tw opened a blank buffer with no error. Root cause chain:
--      vim.fn.system merges stderr into stdout, so any Taskwarrior chatter
--      (news nag, override notices, hook output) around the JSON made
--      tw_export's parse fail, which it silently treated as "zero tasks";
--      a zero-task render is only the concealed header comment → visually
--      blank, and :TwRefresh re-renders the same thing → "no effect".
-- #4 — <Tab> in the :TwFilter/<leader>tf input() replaced the ENTIRE typed
--      filter with the completed token (input() completion is whole-line).
--      Bonus: the gm modify prompt referenced _complete_modify which was
--      never defined, so <Tab> there raised E117.
-- #3 — wrap is now configurable (setup{ wrap = false }); the Apply/Cancel
--      picker focus fix is exercised by the e2e confirm-mode tests.

local eq = assert.are.same

describe("issue #5 — decode_json_array robustness", function()
  local tm = require("taskwarrior.taskmd")
  local TASK = '{"uuid":"abcd1234-0000-0000-0000-000000000000","description":"noisy","status":"pending"}'

  it("decodes clean output", function()
    local t = tm.decode_json_array("[" .. TASK .. "]")
    eq(1, #t)
    eq("noisy", t[1].description)
  end)

  it("decodes an empty array", function()
    eq({}, tm.decode_json_array("[]"))
  end)

  it("decodes with leading noise (task news nag)", function()
    local out = "Recently upgraded. Please run 'task news'.\n[" .. TASK .. "]\n"
    eq("noisy", tm.decode_json_array(out)[1].description)
  end)

  it("decodes with trailing noise", function()
    local out = "[" .. TASK .. "]\nThere are 3 local changes. Sync required.\n"
    eq("noisy", tm.decode_json_array(out)[1].description)
  end)

  it("decodes when surrounding noise itself contains brackets", function()
    local out = "warning [hook on-launch] something\n["
      .. TASK .. "]\nnote: see task(1) [manual]\n"
    eq("noisy", tm.decode_json_array(out)[1].description)
  end)

  it("returns nil on garbage instead of a bogus table", function()
    eq(nil, tm.decode_json_array("task: unexpected error [code 5]"))
    eq(nil, tm.decode_json_array("no brackets at all"))
  end)

  it("decodes output wrapped in ANSI color escapes (forced-color configs)", function()
    local out = "\27[33mPlease run 'task news'.\27[0m\n\27[32m["
      .. TASK .. "]\27[0m\n"
    eq("noisy", tm.decode_json_array(out)[1].description)
  end)

  it("decodes when many bracketed noise lines precede the JSON", function()
    local noise = {}
    for i = 1, 15 do noise[#noise + 1] = ("[warn %d] chatter line"):format(i) end
    local out = table.concat(noise, "\n") .. "\n[" .. TASK .. "]\n"
    eq("noisy", tm.decode_json_array(out)[1].description)
  end)

  it("decodes TW3 line-per-task output with chatter interleaved between lines", function()
    local out = table.concat({
      "hook says hi",
      "[",
      TASK .. ",",
      "hook says hi again",
      '{"uuid":"beef0002-0000-0000-0000-000000000000","description":"second","status":"pending"}',
      "]",
      "trailing chatter",
    }, "\n")
    local t = tm.decode_json_array(out)
    assert.is_not_nil(t, "interleaved chatter must not defeat the decoder")
    eq(2, #t)
    eq("second", t[2].description)
  end)
end)

describe("issue #5 — line-list helpers reject chatter lines", function()
  local runtime = require("taskwarrior.runtime")
  local orig_system, orig_executable

  before_each(function()
    orig_system, orig_executable = vim.fn.system, vim.fn.executable
    runtime._reset_for_tests()
    vim.fn.executable = function(_) return 1 end
  end)

  after_each(function()
    vim.fn.system, vim.fn.executable = orig_system, orig_executable
    runtime._reset_for_tests()
  end)

  local function stub_task_output(text)
    vim.fn.system = function(_)
      orig_system("true")
      return text
    end
  end

  it("tw_completions drops nag lines from _projects/_tags", function()
    stub_task_output("Please run 'task news'.\nwork\nhome\n")
    local c = require("taskwarrior.taskmd").tw_completions()
    eq({ "work", "home" }, c.projects)
    eq({ "work", "home" }, c.tags)
  end)

  it("tw_udas drops nag lines from _udas", function()
    stub_task_output("There are 3 local changes. Sync required.\nutility\nbrainpower\n")
    eq({ "utility", "brainpower" }, require("taskwarrior.taskmd").tw_udas())
  end)
end)

describe("issue #5 — tw_export must not silently return zero tasks", function()
  local runtime = require("taskwarrior.runtime")
  local orig_system, orig_executable

  before_each(function()
    orig_system, orig_executable = vim.fn.system, vim.fn.executable
    runtime._reset_for_tests()
    vim.fn.executable = function(_) return 1 end
  end)

  after_each(function()
    vim.fn.system, vim.fn.executable = orig_system, orig_executable
    runtime._reset_for_tests()
  end)

  -- Sets vim.v.shell_error to 0 (it is read-only, so run a real command),
  -- then returns the fake merged stdout+stderr.
  local function stub_task_output(text)
    vim.fn.system = function(_)
      orig_system("true")
      return text
    end
  end

  it("parses tasks despite stderr noise merged into the output", function()
    stub_task_output("Configuration override rc.json.array:on\n"
      .. "Please run 'task news'.\n"
      .. '[{"uuid":"abcd1234-0000-0000-0000-000000000000","description":"survives","status":"pending"}]\n'
      .. "TASKRC override: /tmp/x\n")
    local tasks = require("taskwarrior.taskmd").tw_export({})
    eq(1, #tasks)
    eq("survives", tasks[1].description)
  end)

  it("raises a diagnosable error on unparseable output (was: silent {})", function()
    stub_task_output("task: something exploded [see log]\n")
    local ok, err = pcall(require("taskwarrior.taskmd").tw_export, {})
    assert.is_false(ok)
    assert.truthy(tostring(err):find("unparseable", 1, true))
  end)
end)

describe("issue #5 — visible empty state", function()
  local buffer = require("taskwarrior.buffer")
  local es_ns = vim.api.nvim_create_namespace("taskwarrior_empty_state")

  local function make_buf(lines, filter)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.b[bufnr].task_filter = filter
    return bufnr
  end

  it("adds a virt_lines hint when the render has no task lines", function()
    local bufnr = make_buf({
      "<!-- taskmd filter: project:nope | sort: urgency- | rendered_at: 2026-01-01T00:00:00 -->",
      "",
    }, "project:nope")
    buffer._apply_empty_state(bufnr)
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, es_ns, 0, -1, { details = true })
    assert.is_true(#marks > 0, "empty render must show a visible hint (issue #5)")
    local text = vim.inspect(marks)
    assert.truthy(text:find("project:nope", 1, true))
  end)

  it("adds no hint when a task line is present", function()
    local bufnr = make_buf({
      "<!-- taskmd filter: status:pending | sort: urgency- | rendered_at: 2026-01-01T00:00:00 -->",
      "",
      "- [ ] real task <!-- uuid:abcd1234 -->",
    }, "")
    buffer._apply_empty_state(bufnr)
    eq({}, vim.api.nvim_buf_get_extmarks(bufnr, es_ns, 0, -1, {}))
  end)

  it("clears a stale hint once tasks appear", function()
    local bufnr = make_buf({ "<!-- taskmd filter: x | sort: urgency- | rendered_at: t -->" }, "x")
    buffer._apply_empty_state(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "- [ ] now here <!-- uuid:beef0001 -->" })
    buffer._apply_empty_state(bufnr)
    eq({}, vim.api.nvim_buf_get_extmarks(bufnr, es_ns, 0, -1, {}))
  end)
end)

describe("issue #4 — input() completion preserves the typed prefix", function()
  local completion = require("taskwarrior.completion")
  local orig_get

  before_each(function()
    orig_get = completion.get_tw_completions
    completion.get_tw_completions = function()
      return { projects = { "home", "work" }, tags = { "next", "later" }, fields = {} }
    end
  end)

  after_each(function()
    completion.get_tw_completions = orig_get
  end)

  it("completes the last token and keeps everything before it", function()
    local results = require("taskwarrior")._complete_filter("", "project:home +n", 15)
    eq({ "project:home +next" }, results)
  end)

  it("completes a bare single token unchanged", function()
    local results = require("taskwarrior")._complete_filter("", "+la", 3)
    eq({ "+later" }, results)
  end)

  it("offers all candidates after a trailing space, prefixed", function()
    local results = require("taskwarrior")._complete_filter("", "project:home ", 13)
    assert.is_true(#results > 0)
    for _, r in ipairs(results) do
      assert.truthy(r:find("project:home ", 1, true) == 1,
        "candidate lost the typed prefix: " .. r)
    end
  end)

  it("_complete_modify is defined (gm <Tab> raised E117 before) and prefixes", function()
    local tw = require("taskwarrior")
    assert.is_function(tw._complete_modify)
    local out = tw._complete_modify("", "due:tomorrow pr", 15)
    assert.is_string(out) -- "custom," completion → newline-separated string
    assert.truthy(out:find("due:tomorrow pr", 1, true) == 1)
  end)
end)

describe("lint — completion= v:lua references resolve", function()
  -- The gm prompt shipped pointing at _complete_modify, which didn't exist;
  -- <Tab> raised E117 (part of issue #4). Nothing type-checks a string
  -- completion= spec, so scan the source for every such reference and
  -- assert the target function is actually defined.
  it("every v:lua.require'taskwarrior'.X used in a completion spec exists", function()
    local root = vim.fn.fnamemodify(
      vim.api.nvim_get_runtime_file("lua/taskwarrior/init.lua", false)[1], ":h")
    local tw = require("taskwarrior")
    local checked = 0
    for _, path in ipairs(vim.fn.glob(root .. "/**/*.lua", false, true)) do
      local f = assert(io.open(path, "r"))
      local src = f:read("*a")
      f:close()
      for name in src:gmatch("v:lua%.require'taskwarrior'%.([%w_]+)") do
        checked = checked + 1
        assert.is_function(tw[name],
          ("%s references v:lua taskwarrior.%s which is not a function"):format(path, name))
      end
    end
    assert.is_true(checked >= 4, "expected to find completion specs, found " .. checked)
  end)
end)

describe("issue #3 — wrap config option", function()
  local config = require("taskwarrior.config")

  it("defaults to true", function()
    config.setup({})
    eq(true, config.options.wrap)
  end)

  it("accepts wrap = false", function()
    config.setup({ wrap = false })
    eq(false, config.options.wrap)
  end)

  it("rejects a non-boolean wrap", function()
    local ok = pcall(config.setup, { wrap = "no" })
    assert.is_false(ok)
    config.setup({}) -- restore sane defaults for later specs
  end)
end)
