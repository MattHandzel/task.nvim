-- prefix_rebrand_lint_spec.lua — guards user-facing strings against
-- hardcoded `:Task<Cmd>` references that drift from the configured
-- command prefix.
--
-- Why: bug #5 (v1.5 QA) — show_verify_buffer hardcoded `:TaskTutor`,
-- bypassing the per-lesson rebrand pass that render_lesson did.
-- Default-prefix users (`:Tw`) saw "re-run :TaskTutor" — broken
-- instructions. Same class of bug appeared in apply.lua's conflict
-- ERROR notify (hardcoded `:TaskRefresh`).
--
-- This spec scans every Lua file for `:Task[A-Z]` literals appearing
-- in code (not comments). Allow-listed sites are the ones whose
-- output is rebranded at render time:
--
--   • lua/taskwarrior/help.lua            — HELP_TEXT runs through prefix.rebrand
--   • lua/taskwarrior/tutor/lessons.lua   — body lines rebranded in render_lesson
--   • lua/taskwarrior/prefix.lua          — the rebrand helper itself
--   • lua/taskwarrior/config.lua          — config docs (gsub source, no output)
--   • lua/taskwarrior/commands.lua        — Ex command registration prose
--
-- Anything else with `:Task[A-Z]` in code is a hardcode bug — emit it
-- through prefix.rebrand or use a `:%sFoo` format-string with the
-- configured prefix.

describe("prefix-rebrand discipline", function()

  -- Allow-list: file-suffix → reason. Files that explicitly route their
  -- :Task<Cmd> literals through `taskwarrior.prefix` at output time are
  -- auto-detected below (we grep their content for the rebrand import).
  -- This list is for files that have legitimate :Task<Cmd> mentions
  -- without using the rebrand module (config docs, Ex command construction).
  local ALLOW_LIST = {
    ["/lua/taskwarrior/prefix.lua"]            = "the rebrand helper itself",
    ["/lua/taskwarrior/config.lua"]            = "config docs (the gsub source string)",
    ["/lua/taskwarrior/commands.lua"]          = "Ex command registration prose; commands themselves are constructed with the prefix",
    ["/lua/taskwarrior/tutor/lessons.lua"]     = "M.lessons[*].body strings; rebranded by render_lesson via the prefix module (it imports through tutor/init.lua, not directly)",
  }

  it("no plugin Lua file has unrebranded :Task<Cmd> in user-facing strings", function()
    local source = debug.getinfo(1, "S").source:sub(2)
    local repo_root = vim.fn.fnamemodify(source, ":h:h:h:h")
    local roots = { "lua", "plugin" }

    -- Strip line comments (`--` to end of line) before matching, so that
    -- explanatory comments mentioning the legacy prefix aren't flagged.
    -- Block comments `--[[ ]]` aren't used in this codebase; if they
    -- appear, the lint may need extending. Simple line-by-line scan.
    local function strip_line_comments(content)
      local out = {}
      for line in content:gmatch("([^\n]*)\n?") do
        -- Find `--` outside of strings. Approximation: locate `--` and
        -- check whether it appears AFTER an odd number of double-quote
        -- characters (i.e. inside a string). Lua's pattern engine isn't
        -- powerful enough for proper string parsing, but this is good
        -- enough for the strings actually used in this project — no
        -- file has `--` embedded inside a string literal that also
        -- contains `:Task<Cmd>`. If that ever changes, the false-
        -- positive will surface here and we revisit.
        local idx = line:find("%-%-")
        if idx then
          -- Count `"` chars before idx; if odd, we're inside a string.
          local before = line:sub(1, idx - 1)
          local quote_count = 0
          for _ in before:gmatch('"') do quote_count = quote_count + 1 end
          if quote_count % 2 == 0 then
            line = before
          end
        end
        out[#out + 1] = line
      end
      return table.concat(out, "\n")
    end

    local offenders = {}
    for _, root in ipairs(roots) do
      local files = vim.fn.glob(repo_root .. "/" .. root .. "/**/*.lua", true, true)
      for _, file in ipairs(files) do
        local rel = file:sub(#repo_root + 1)
        local skip = ALLOW_LIST[rel] ~= nil
        if not skip then
          local fh = io.open(file, "r")
          if fh then
            local content = fh:read("*all")
            fh:close()
            -- Auto-allow files that import the rebrand module — every
            -- :Task<Cmd> literal in those files is presumed to be fed
            -- through prefix.rebrand at output time.
            if content:find('require%([\'"]taskwarrior%.prefix[\'"]%)') then
              skip = true
            end
            if not skip then
            local stripped = strip_line_comments(content)
            -- Match `:Task` followed by an uppercase letter (the
            -- start of a command suffix like `:TaskFilter`). The bare
            -- `:Task` is the open command and is also caught.
            -- Pattern guards against matching task descriptions like
            -- "edit the :Task buffer" — we want command references.
            if stripped:find(":Task[A-Z]") or stripped:find(":Task[%s%p]") then
              -- Filter: re-search the stripped content for line numbers
              -- to make the failure message actionable.
              local hits = {}
              local lnum = 0
              for line in stripped:gmatch("([^\n]*)\n?") do
                lnum = lnum + 1
                if line:find(":Task[A-Z]") or line:find(":Task[%s%p]") then
                  hits[#hits + 1] = string.format("    %s:%d  %s", rel, lnum, vim.trim(line))
                end
              end
              if #hits > 0 then
                offenders[#offenders + 1] = table.concat(hits, "\n")
              end
            end
            end  -- close `if not skip`
          end
        end
      end
    end

    if #offenders > 0 then
      assert(false,
        "hardcoded :Task<Cmd> references found in user-facing strings:\n"
          .. table.concat(offenders, "\n")
          .. "\n\nRoute through require('taskwarrior.prefix').rebrand() so the"
          .. " text matches the user's configured command_prefix. If the"
          .. " literal is intentional (e.g. inside a rebrand source), add"
          .. " the file path to ALLOW_LIST in this spec with a justifying comment."
      )
    end
  end)

  describe("prefix.rebrand semantics", function()
    -- Each test resets config so prefix doesn't leak between tests.
    local prefix_mod = require("taskwarrior.prefix")
    local config = require("taskwarrior.config")

    before_each(function()
      -- Reset state. vim.g.taskwarrior_command_prefix takes priority
      -- over setup() opts (issue #1 reconciliation in config.setup),
      -- so we must clear vim.g first to let the test's `command_prefix`
      -- override actually apply.
      vim.g.taskwarrior_command_prefix = nil
      config.setup({ command_prefix = "Tw" })
    end)

    it("rewrites every :Task<Cmd> to :<prefix><Cmd>", function()
      assert.equals(":Tw",        prefix_mod.rebrand(":Task"))
      assert.equals(":TwFilter",  prefix_mod.rebrand(":TaskFilter"))
      assert.equals("Run :TwTutor reset.", prefix_mod.rebrand("Run :TaskTutor reset."))
    end)

    it("is a no-op when command_prefix == 'Task' (the legacy default)", function()
      vim.g.taskwarrior_command_prefix = nil
      config.setup({ command_prefix = "Task" })
      assert.equals(":TaskFilter", prefix_mod.rebrand(":TaskFilter"))
    end)

    it("handles a table-of-strings input", function()
      local out = prefix_mod.rebrand({ ":TaskFilter foo", ":TaskGroup project" })
      assert.equals(":TwFilter foo",   out[1])
      assert.equals(":TwGroup project", out[2])
    end)

    it("returns a fresh table (does not mutate input)", function()
      local input = { ":TaskFilter" }
      local out = prefix_mod.rebrand(input)
      assert.is_not.equal(input, out)
      assert.equals(":TaskFilter", input[1])  -- input untouched
      assert.equals(":TwFilter",   out[1])
    end)
  end)
end)
