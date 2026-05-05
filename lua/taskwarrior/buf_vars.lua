-- buf_vars.lua — single source of truth for buffer-local variable names.
--
-- Why this module exists. Bug #4 (v1.5 QA): feedback/context.lua read
-- vim.b[buf].taskwarrior_filter / _sort / _group, but buffer.lua wrote
-- vim.b[bufnr].task_filter / .task_sort / .task_group. The names drifted
-- silently — no test exercised both halves of the contract — and every
-- :TwFeedback report from inside a :Tw buffer showed `<unknown>` for
-- filter/sort/group.
--
-- Fix pattern: a single module exporting the canonical names as
-- constants. All readers and writers go through M.get / M.set, never
-- through `vim.b[buf].<literal>`. A lint-spec asserts the discipline.
--
-- See tests/lua/spec/buf_vars_lint_spec.lua.

local M = {}

-- Canonical names. Anything that wants to read/write task-buffer state
-- must use these constants.
M.FILTER = "task_filter"
M.SORT   = "task_sort"
M.GROUP  = "task_group"

-- Last-action-count for :TwUndo, set by apply.do_apply_and_refresh.
M.LAST_ACTION_COUNT = "task_last_action_count"

--- Return vim.b[buf][var]. Falls back to nil cleanly for invalid buffers
--- so callers don't have to guard.
function M.get(buf, var)
  local ok, val = pcall(function() return vim.b[buf][var] end)
  if not ok then return nil end
  return val
end

--- Set vim.b[buf][var] = val. Returns true on success.
function M.set(buf, var, val)
  local ok = pcall(function() vim.b[buf][var] = val end)
  return ok
end

--- True if `buf` is a task buffer (i.e. has the FILTER var set, even to "").
--- This is the canonical "is this a :Tw buffer?" check — many call sites
--- previously did `vim.b[bufnr].task_filter == nil` which didn't survive
--- the rename.
function M.is_task_buffer(buf)
  return M.get(buf, M.FILTER) ~= nil
end

return M
