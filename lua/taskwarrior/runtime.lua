-- runtime.lua — single source of truth for runtime environment checks.
--
-- Why this module exists. Before v1.5, the plugin had four independent
-- copies of `vim.fn.executable("task") == 1` (plugin/, taskmd.lua,
-- health.lua, tutor/lessons.lua). They drifted: the Layer-A startup
-- WARN fired correctly, but downstream call sites (Python fallback,
-- healthcheck data-location block) ran `task` anyway and surfaced
-- secondary errors. Centralising the check here means every site goes
-- through one function with one notification policy.
--
-- Per-session caching. `vim.fn.executable` is cheap, but the WARN
-- attached to the first miss must fire AT MOST ONCE per session — that
-- discipline is impossible to maintain when four files each own a flag.
-- This module owns the flag.
--
-- Tests: a lint-spec asserts grep -rE 'vim\.fn\.executable\(.task.\)'
-- matches only this file.

local M = {}

-- Cached state for the current session.
--   _checked      — set true after the first call, never reset.
--   _available    — outcome of the first check (boolean).
--   _notified     — set true after the first WARN to suppress subsequent.
local _checked, _available, _notified = false, false, false

-- The exact WARN copy emitted for missing-binary first-touch. Kept here
-- (single string) so spec assertions can match against this constant
-- rather than fragile substring matching against changeable copy.
M.MISSING_BINARY_MESSAGE = table.concat({
  "taskwarrior.nvim: `task` not found on PATH.",
  "Install Taskwarrior from https://taskwarrior.org/install/ and ensure "
    .. "the `task` binary is on PATH (or set vim.env.PATH from your nvim config "
    .. "if it lives somewhere unusual).",
  "Run :checkhealth taskwarrior after installing to verify.",
}, "\n")

--- Test-only — clears caches so a spec can re-exercise the first-touch path.
--- Production callers must NOT use this.
function M._reset_for_tests()
  _checked, _available, _notified = false, false, false
end

--- Returns true iff a `task` binary is callable.
--- Cached per session — runs vim.fn.executable exactly once.
--- Does NOT emit any notification. Use `ensure_available` for that.
function M.is_task_available()
  if not _checked then
    _checked = true
    _available = (vim.fn.executable("task") == 1)
  end
  return _available
end

--- Returns true iff a `task` binary is callable, AND emits the missing-
--- binary WARN at most once per session if not. Returns boolean so callers
--- can early-return without their own notification.
---
--- Use this at the top of any code path that is about to spawn `task`.
--- The Layer-A startup-time check in plugin/taskwarrior.lua and the
--- Layer-B per-call check in lua/taskwarrior/taskmd.lua run() both go
--- through here so the WARN fires exactly once across the whole plugin.
function M.ensure_available()
  if M.is_task_available() then return true end
  if not _notified then
    _notified = true
    vim.notify(M.MISSING_BINARY_MESSAGE, vim.log.levels.WARN)
  end
  return false
end

return M
