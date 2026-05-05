-- taskwarrior.nvim plugin entrypoint.
-- Registers user commands even if the user hasn't called setup() yet. Each
-- command lazy-loads the real module and forwards args, so startup cost is
-- essentially zero for users who never run :Task.

if vim.g.loaded_taskwarrior == 1 then return end
vim.g.loaded_taskwarrior = 1

if vim.fn.has("nvim-0.9") ~= 1 then
  vim.notify("taskwarrior.nvim requires Neovim >= 0.9", vim.log.levels.ERROR)
  return
end

-- Layer A — startup-time dependency check. Without this, the first call
-- to vim.fn.system({"task",...}) raises `E475: Invalid value for argument
-- cmd: 'task' is not executable` from inside vim.schedule, which the user
-- sees as an unintelligible Lua stack trace (cf. issue #2). Fail loud and
-- friendly instead. Plugin commands stay registered; they no-op safely
-- via the Layer-B check in lua/taskwarrior/taskmd.lua run().
--
-- Routed through lua/taskwarrior/runtime.lua so the WARN copy + once-per-
-- session throttle is owned in one place.
require("taskwarrior.runtime").ensure_available()

local function lazy(method)
  return function(cmd_opts)
    local ok, task = pcall(require, "taskwarrior")
    if not ok then
      vim.notify("taskwarrior.nvim: failed to load — " .. tostring(task), vim.log.levels.ERROR)
      return
    end
    -- Ensure setup() has run at least once so config defaults are populated.
    if type(task.setup) == "function" and not vim.g._taskwarrior_setup_done then
      pcall(task.setup, {})
      vim.g._taskwarrior_setup_done = 1
    end
    local fn = task[method]
    if type(fn) ~= "function" then
      vim.notify("taskwarrior.nvim: method not available — " .. method, vim.log.levels.ERROR)
      return
    end
    return fn(cmd_opts and cmd_opts.args or nil, cmd_opts)
  end
end

-- Primary command. All other commands are created inside setup() — we only
-- define :<prefix> here as the lazy entrypoint so users get a clear error
-- rather than "command not found" when they haven't called setup() yet.
--
-- Issue #1: the prefix is configurable. We read vim.g.taskwarrior_command_prefix
-- here because plugin/ runs BEFORE the user's setup() call, so config.options
-- isn't populated yet. Users override the lazy command name by setting
-- vim.g.taskwarrior_command_prefix in their init (lazy.nvim users: in the
-- spec's `init = function() … end` block, which runs at load time).
--
-- Default fell from "Task" → "Tw" in v1.4.1 to resolve issue #1 collision
-- with Shatur/neovim-tasks. Must match the `command_prefix` default in
-- lua/taskwarrior/config.lua (which the rest of the plugin reads after
-- setup) — otherwise the lazy `:Task` and the post-setup `:Tw` would
-- co-exist as orphans of each other.
local lazy_prefix = vim.g.taskwarrior_command_prefix or "Tw"
if lazy_prefix:match("^[A-Z][A-Za-z]*$") then
  vim.api.nvim_create_user_command(lazy_prefix, function(cmd_opts)
    local ok, task = pcall(require, "taskwarrior")
    if not ok then
      vim.notify("taskwarrior.nvim: failed to load — " .. tostring(task), vim.log.levels.ERROR)
      return
    end
    if type(task.setup) == "function" and not vim.g._taskwarrior_setup_done then
      pcall(task.setup, {})
      vim.g._taskwarrior_setup_done = 1
    end
    task.open(cmd_opts.args)
  end, {
    nargs = "*",
    desc = "Open Taskwarrior tasks as markdown",
  })
  -- Sentinel: commands.lua's collision detector reads this so it doesn't
  -- shout "another plugin already registered :<prefix>!" against our own
  -- lazy registration. Without this, every default install fires a
  -- false-positive WARN at startup.
  vim.g._taskwarrior_lazy_owned_command = lazy_prefix
else
  vim.notify(
    ("taskwarrior.nvim: invalid vim.g.taskwarrior_command_prefix '%s' — "
      .. "must match ^[A-Z][A-Za-z]*$. Lazy entrypoint not registered; "
      .. "fix your prefix and restart."):format(lazy_prefix),
    vim.log.levels.ERROR
  )
end

_G._taskwarrior_lazy = lazy  -- kept for future use; not publicly documented

-- Auto-generate help tags so `:help taskwarrior` works without the user
-- having to run `:helptags ALL` themselves. lazy.nvim does this on
-- install, but users who clone manually, switch branches, or use a
-- different plugin manager hit `E149: Sorry, no help for taskwarrior`
-- on first try. Idempotent: only re-runs if doc/taskwarrior.txt is
-- newer than doc/tags (or tags is missing).
do
  local source = debug.getinfo(1, "S").source:sub(2)
  local doc_dir = vim.fn.fnamemodify(source, ":h:h") .. "/doc"
  if vim.fn.isdirectory(doc_dir) == 1 then
    local tags_file = doc_dir .. "/tags"
    local txt_file  = doc_dir .. "/taskwarrior.txt"
    local tags_mt = vim.fn.getftime(tags_file)
    local txt_mt  = vim.fn.getftime(txt_file)
    if tags_mt == -1 or (txt_mt > 0 and txt_mt > tags_mt) then
      pcall(vim.cmd, "silent! helptags " .. vim.fn.fnameescape(doc_dir))
    end
  end
end
