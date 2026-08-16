-- Regression spec for the hyphenated-tag class of bugs.
--
-- TW3's expression parser treats `-` inside a bare `+tag` token as a
-- subtraction operator:
--   * filter `+ais-research-taste`  → "Cannot subtract from a Boolean value"
--   * `add … +ais-research-taste`   → tag silently lands in the description
--   * `modify +ais-research-taste`  → exit 2 (or silent no-op with `--`)
--
-- Fixes under test:
--   1. shell_export routes parsed args through normalize_tag_filters
--      (`+t` → `tags.has:t`, `-t` → `tags.hasnt:t`, virtual tags verbatim).
--   2. fields_to_args emits a single `tags:a,b` replacement arg instead of
--      per-tag `+a +b` deltas (also fixes partial tag removal on save).
--   3. tw_change_tag merges a single-tag delta into the full set and
--      replaces, instead of `modify +t` / `modify -t`.

local eq = assert.are.same

local tm = require("taskwarrior.taskmd")
local command = require("taskwarrior.command")
local runtime = require("taskwarrior.runtime")

describe("hyphen tags — fields_to_args replacement semantics", function()
  it("emits one tags: arg for the full set", function()
    local args = tm._fields_to_args({ tags = { "plain", "with-hyphens" } })
    eq({ "tags:plain,with-hyphens" }, args)
  end)

  it("emits an empty tags: to clear all tags", function()
    local args = tm._fields_to_args({ tags = {}, _removed_tags = { "old-tag" } })
    eq({ "tags:" }, args)
  end)

  it("never emits +tag or -tag delta args", function()
    local args = tm._fields_to_args({
      tags = { "keep-me" }, _removed_tags = { "drop-me" }, project = "p",
    })
    for _, a in ipairs(args) do
      assert.is_nil(a:match("^[%+%-]"), "unexpected delta arg: " .. a)
    end
  end)
end)

describe("hyphen tags — shell_export filter normalization", function()
  local orig_read, orig_executable
  local captured

  before_each(function()
    captured = nil
    orig_read = command.read
    orig_executable = vim.fn.executable
    vim.fn.executable = function(_) return 1 end
    runtime._reset_for_tests()
    command.read = function(args, _)
      captured = args
      return { ok = true, output = "[]", code = 0 }
    end
  end)

  after_each(function()
    command.read = orig_read
    vim.fn.executable = orig_executable
    runtime._reset_for_tests()
  end)

  local function exported_args(filter)
    tm.shell_export(filter)
    assert.is_table(captured, "command.read was not invoked")
    return captured
  end

  it("rewrites +tag to tags.has:", function()
    local args = exported_args("+ais-research-taste status:pending")
    eq("tags.has:ais-research-taste", args[2])
    eq("status:pending", args[3])
  end)

  it("rewrites -tag to tags.hasnt:", function()
    local args = exported_args("-ais-research-taste")
    eq("tags.hasnt:ais-research-taste", args[2])
  end)

  it("keeps virtual tags verbatim", function()
    local args = exported_args("+ACTIVE")
    eq("+ACTIVE", args[2])
  end)
end)

describe("hyphen tags — tw_change_tag merge-and-replace", function()
  local orig_export, orig_modify
  local modify_calls

  before_each(function()
    modify_calls = {}
    orig_export = tm.shell_export
    orig_modify = tm.tw_modify
    tm.tw_modify = function(uuid, fields)
      modify_calls[#modify_calls + 1] = { uuid = uuid, fields = fields }
      return true, "", 0
    end
  end)

  after_each(function()
    tm.shell_export = orig_export
    tm.tw_modify = orig_modify
  end)

  local function with_task_tags(tags)
    tm.shell_export = function(_)
      return { { uuid = "u-1", tags = tags } }
    end
  end

  it("appends a tag to the existing set", function()
    with_task_tags({ "existing" })
    local ok = tm.tw_change_tag("u-1", "new-hyphen-tag")
    assert.is_true(ok)
    eq({ "existing", "new-hyphen-tag" }, modify_calls[1].fields.tags)
  end)

  it("is a no-op when the tag is already present", function()
    with_task_tags({ "already-there" })
    local ok = tm.tw_change_tag("u-1", "already-there")
    assert.is_true(ok)
    eq(0, #modify_calls)
  end)

  it("removes a tag, keeping the rest", function()
    with_task_tags({ "keep-this", "drop-this" })
    local ok = tm.tw_change_tag("u-1", "drop-this", true)
    assert.is_true(ok)
    eq({ "keep-this" }, modify_calls[1].fields.tags)
  end)

  it("fails closed when the task cannot be read", function()
    tm.shell_export = function(_) return nil end
    local ok, out = tm.tw_change_tag("u-1", "anything")
    assert.is_false(ok)
    assert.is_truthy(out:match("could not read task"))
    eq(0, #modify_calls)
  end)
end)
