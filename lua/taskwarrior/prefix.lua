-- prefix.lua — single source of truth for command-prefix rebranding.
--
-- Any user-facing string that references plugin commands as `:Task<Cmd>`
-- must run through M.rebrand before being shown to the user, so the
-- text matches the prefix the user actually configured (default `:Tw`,
-- override via vim.g.taskwarrior_command_prefix or setup({command_prefix=...})).
--
-- Call sites:
--   • lua/taskwarrior/help.lua       — :TwHelp output
--   • lua/taskwarrior/tutor/init.lua — render_lesson per-line rebrand
--   • lua/taskwarrior/apply.lua      — conflict ERROR notify
--   • lua/taskwarrior/health.lua     — plugin-data dir hint message
--
-- Bug #5 (v1.5 QA): the tutor's verify-buffer (since removed in v1.5)
-- hardcoded `:TaskTutor` and didn't run the rebrand pass that
-- render_lesson did. Default-prefix users saw "re-run :TaskTutor" — a
-- command that doesn't exist on their install. Centralising here means
-- every site uses the same pattern, and the lint spec
-- (tests/lua/spec/prefix_rebrand_lint_spec.lua) keeps new sites from
-- re-introducing the same hardcode.

local M = {}

--- Read the configured prefix or fall back to "Task" (the historical default
--- before v1.4.1; rebrand against this means "no-op").
local function current_prefix()
  local ok, config = pcall(require, "taskwarrior.config")
  if ok and config.options and type(config.options.command_prefix) == "string" then
    return config.options.command_prefix
  end
  return "Task"
end

--- Rewrite every literal `:Task<Cmd>` in `text` to `:<prefix><Cmd>`.
--- Works because `Task` is a prefix of every plugin command name and
--- a single gsub catches `:Task`, `:TaskFilter`, `:TaskSort`, etc.
--- When prefix == "Task" the substitution is a no-op.
---
--- Accepts a string OR a table-of-strings. For the table form, returns
--- a new table with each element rewritten; useful when feeding
--- nvim_buf_set_lines.
function M.rebrand(text)
  local prefix = current_prefix()
  if type(text) == "string" then
    return (text:gsub(":Task", ":" .. prefix))
  elseif type(text) == "table" then
    local out = {}
    for i, line in ipairs(text) do
      out[i] = type(line) == "string" and (line:gsub(":Task", ":" .. prefix)) or line
    end
    return out
  else
    error("prefix.rebrand: expected string or table, got " .. type(text), 2)
  end
end

return M
