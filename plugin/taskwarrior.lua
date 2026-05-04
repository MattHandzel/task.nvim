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
-- via Layer B in lua/taskwarrior/taskmd.lua run().
if vim.fn.executable("task") ~= 1 then
  vim.notify(
    "taskwarrior.nvim: `task` not found on PATH.\n"
      .. "Install Taskwarrior from https://taskwarrior.org/install/ and ensure "
      .. "the `task` binary is on PATH (or set vim.env.PATH from your nvim config "
      .. "if it lives somewhere unusual).\n"
      .. "Run :checkhealth taskwarrior after installing to verify.",
    vim.log.levels.WARN
  )
end

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
local lazy_prefix = vim.g.taskwarrior_command_prefix or "Task"
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
else
  vim.notify(
    ("taskwarrior.nvim: invalid vim.g.taskwarrior_command_prefix '%s' — "
      .. "must match ^[A-Z][A-Za-z]*$. Lazy entrypoint not registered; "
      .. "fix your prefix and restart."):format(lazy_prefix),
    vim.log.levels.ERROR
  )
end

_G._taskwarrior_lazy = lazy  -- kept for future use; not publicly documented
