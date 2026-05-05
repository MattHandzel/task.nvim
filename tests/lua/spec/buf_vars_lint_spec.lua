-- buf_vars_lint_spec.lua — guards the canonical buffer-var names.
--
-- Why: bug #4 (v1.5 QA) was buffer.lua writing `task_filter` while
-- feedback/context.lua read `taskwarrior_filter`. The drift was silent
-- — the read returned nil, the formatter printed `<unknown>`, and no
-- test exercised the cross-module contract.
--
-- This spec asserts that:
-- 1. The canonical names live in lua/taskwarrior/buf_vars.lua.
-- 2. Code that needs filter/sort/group goes through buf_vars (or, for
--    legacy reasons that pre-date the module, uses the same string
--    literals it exports).
--
-- Strict-mode (rule 2) is currently advisory: many call sites still use
-- vim.b[buf].task_filter directly, and migrating them all is a separate
-- refactor. The lint instead checks that NOBODY uses the WRONG name —
-- the previous bug would still fail today.

describe("buf_vars — canonical buffer-var names", function()
  local buf_vars = require("taskwarrior.buf_vars")

  it("exports FILTER / SORT / GROUP as documented strings", function()
    assert.equals("task_filter", buf_vars.FILTER)
    assert.equals("task_sort",   buf_vars.SORT)
    assert.equals("task_group",  buf_vars.GROUP)
  end)

  it("get / set round-trip a value", function()
    local buf = vim.api.nvim_create_buf(false, true)
    assert.is_nil(buf_vars.get(buf, buf_vars.FILTER))
    assert.is_true(buf_vars.set(buf, buf_vars.FILTER, "+work"))
    assert.equals("+work", buf_vars.get(buf, buf_vars.FILTER))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("is_task_buffer is true iff FILTER var is set", function()
    local buf = vim.api.nvim_create_buf(false, true)
    assert.is_false(buf_vars.is_task_buffer(buf))
    buf_vars.set(buf, buf_vars.FILTER, "")
    assert.is_true(buf_vars.is_task_buffer(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- The drift bug we caught: feedback/context.lua read taskwarrior_filter
  -- while buffer.lua wrote task_filter. Lint forbids the WRONG names from
  -- appearing as buffer-variable accesses (`vim.b[…].taskwarrior_*`) or
  -- assignments (`taskwarrior_filter =`) anywhere in source files.
  -- Plain doc-comment mentions of the historical name are tolerated since
  -- they're explanatory; the patterns below only catch real usages.
  it("no module accesses vim.b[…].taskwarrior_(filter|sort|group) — wrong names", function()
    local source = debug.getinfo(1, "S").source:sub(2)
    local repo_root = vim.fn.fnamemodify(source, ":h:h:h:h")
    local roots = { "lua", "plugin" }

    -- Patterns that constitute a real read or write of the wrong name.
    -- Doc comments referencing the literal token (in prose) won't match.
    local bad_patterns = {
      "vim%.b%[[^%]]+%]%.taskwarrior_filter",
      "vim%.b%[[^%]]+%]%.taskwarrior_sort",
      "vim%.b%[[^%]]+%]%.taskwarrior_group",
    }

    local offenders = {}
    for _, root in ipairs(roots) do
      local files = vim.fn.glob(repo_root .. "/" .. root .. "/**/*.lua", true, true)
      for _, file in ipairs(files) do
        -- Allow-list: buf_vars.lua may name the historical bad names in
        -- its header comment as documentation of why the module exists.
        if not file:match("/lua/taskwarrior/buf_vars%.lua$") then
          local fh = io.open(file, "r")
          if fh then
            local content = fh:read("*all")
            fh:close()
            for _, pat in ipairs(bad_patterns) do
              if content:match(pat) then
                -- gsub returns (string, n_subs); wrap in parens to discard count.
                table.insert(offenders, (file:gsub(repo_root .. "/", "")))
                break
              end
            end
          end
        end
      end
    end

    if #offenders > 0 then
      assert(false,
        "found stale buffer-var accesses (vim.b[…].taskwarrior_filter / _sort / _group) in:\n  "
          .. table.concat(offenders, "\n  ")
          .. "\nUse buf_vars.FILTER / .SORT / .GROUP and access via buf_vars.get/set."
      )
    end
  end)

  -- Round-trip contract: writing via buffer.lua and reading via the
  -- feedback context must agree on the var name. This is the cross-
  -- module test that bug #4 lacked.
  it("buffer-write + context-read see the same value", function()
    local buf = vim.api.nvim_create_buf(false, true)
    -- Write the way buffer.lua does (direct vim.b assignment).
    vim.b[buf].task_filter = "+work"
    vim.b[buf].task_sort   = "due+"
    vim.b[buf].task_group  = "project"

    -- Read the way feedback/context.lua does.
    local ctx = require("taskwarrior.feedback.context")
    local snap = ctx.capture(buf, 1, { scrub = false, radius = 0 })

    assert.equals("+work",   snap.filter)
    assert.equals("due+",    snap.sort)
    assert.equals("project", snap.group)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
