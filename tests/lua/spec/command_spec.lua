local command = require("taskwarrior.command")
local runtime = require("taskwarrior.runtime")

describe("taskwarrior.command", function()
  local original_system
  local original_jobstart
  local original_available

  before_each(function()
    original_system = vim.fn.system
    original_jobstart = vim.fn.jobstart
    original_available = runtime.ensure_available
    runtime.ensure_available = function() return true end
  end)

  after_each(function()
    vim.fn.system = original_system
    vim.fn.jobstart = original_jobstart
    runtime.ensure_available = original_available
  end)

  local function stub_exit(code, output, capture)
    vim.fn.system = function(argv)
      capture.argv = vim.deepcopy(argv)
      original_system(code == 0 and "true" or "false")
      return output or ""
    end
  end

  it("builds mutation argv and returns explicit success metadata", function()
    local capture = {}
    stub_exit(0, "ok", capture)

    local result = command.mutate({ "abc123", "done" })

    assert.is_true(result.ok)
    assert.are.equal(0, result.code)
    assert.are.equal("ok", result.output)
    assert.are.same({
      "task", "rc.bulk=0", "rc.confirmation=off", "abc123", "done",
    }, capture.argv)
  end)

  it("marks non-zero mutation exits as failures", function()
    local capture = {}
    stub_exit(1, "denied", capture)

    local result = command.mutate({ "abc123", "done" })

    assert.is_false(result.ok)
    assert.are.equal(1, result.code)
    assert.are.equal("denied", result.output)
  end)

  it("adds output-suppression rc overrides to reads", function()
    local capture = {}
    stub_exit(0, "[]", capture)

    command.read({ "status:pending", "export" })

    assert.are.same({
      "task", "rc.bulk=0", "rc.confirmation=off",
      "rc.verbose=nothing", "rc.color=off", "status:pending", "export",
    }, capture.argv)
  end)

  it("keeps every user value in a distinct argv element", function()
    local capture = {}
    stub_exit(0, "", capture)

    command.mutate({ "abc123", "annotate", "quoted ' text; $(ignored)" })

    assert.are.equal("quoted ' text; $(ignored)", capture.argv[#capture.argv])
  end)

  it("parses quoted argument strings without invoking a shell", function()
    assert.are.same(
      { "project:Home Office", "+next", "description:quoted value" },
      command.parse_args([[project:"Home Office" +next 'description:quoted value']]))
  end)

  it("rejects malformed quoted argument strings", function()
    local args, err = command.parse_args([[project:"unfinished]])
    assert.is_nil(args)
    assert.is_truthy(err:find("unclosed quote", 1, true))
  end)

  it("does not spawn when Taskwarrior is unavailable", function()
    runtime.ensure_available = function() return false end
    local called = false
    vim.fn.system = function() called = true end

    local result = command.mutate({ "add", "description:x" })

    assert.is_false(called)
    assert.is_false(result.ok)
    assert.are.equal(127, result.code)
    assert.are.equal("unavailable", result.reason)
  end)

  it("supports explicitly accepted read exit codes", function()
    local capture = {}
    stub_exit(1, "[]", capture)

    local result = command.read({ "export" }, { ok_codes = { 0, 1 } })

    assert.is_true(result.ok)
    assert.are.equal(1, result.code)
  end)

  it("uses the same result contract for asynchronous commands", function()
    local captured_argv
    vim.fn.jobstart = function(argv, opts)
      captured_argv = vim.deepcopy(argv)
      opts.on_stdout(1, { "sync output" })
      opts.on_stderr(1, { "sync warning" })
      opts.on_exit(1, 0)
      return 42
    end
    local result

    local job = command.start({ "sync" }, { kind = "mutation" }, function(value)
      result = value
    end)

    assert.are.equal(42, job)
    assert.is_true(result.ok)
    assert.are.equal(0, result.code)
    assert.are.equal("sync output", result.output)
    assert.are.equal("sync warning", result.stderr)
    assert.are.same({
      "task", "rc.bulk=0", "rc.confirmation=off", "sync",
    }, captured_argv)
  end)

  it("converts asynchronous spawn exceptions into failure results", function()
    vim.fn.jobstart = function() error("synthetic spawn failure") end
    local result

    local job = command.start({ "sync" }, { kind = "mutation" }, function(value)
      result = value
    end)

    assert.is_nil(job)
    assert.is_false(result.ok)
    assert.are.equal(-1, result.code)
    assert.are.equal("spawn-error", result.reason)
    assert.is_truthy(result.output:find("synthetic spawn failure", 1, true))
  end)
end)
