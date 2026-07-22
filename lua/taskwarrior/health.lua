local M = {}
local command = require("taskwarrior.command")

M.check = function()
  vim.health.start("taskwarrior.nvim")

  -- Neovim version
  if vim.fn.has("nvim-0.9") == 1 then
    vim.health.ok("Neovim >= 0.9")
  else
    vim.health.error("Neovim >= 0.9 required")
  end

  -- Taskwarrior
  if require("taskwarrior.runtime").is_task_available() then
    local tw_version = command.read({ "--version" }, { rc = {} }).output:gsub("%s+$", "")
    local major = tonumber(tw_version:match("^(%d+)"))
    if major and major >= 2 then
      vim.health.ok("Taskwarrior " .. tw_version)
    else
      vim.health.warn("Taskwarrior version may be too old: " .. tw_version)
    end
  else
    vim.health.error("Taskwarrior not found", "Install: https://taskwarrior.org")
  end

  -- Task data directory. Skip when `task` is missing — `task _get` would
  -- silently shell-fail and we'd report a bogus default path.
  if require("taskwarrior.runtime").is_task_available() then
    local taskdata = command.read({ "_get", "rc.data.location" }).output:gsub("%s+$", "")
    if taskdata ~= "" and vim.fn.isdirectory(taskdata) == 1 then
      vim.health.ok("Taskwarrior data at " .. taskdata)
    else
      local default = vim.fn.expand("~/.task")
      if vim.fn.isdirectory(default) == 1 then
        vim.health.ok("Taskwarrior data at " .. default)
      else
        vim.health.warn(
          "Taskwarrior data directory not found",
          "Run `task add 'first task'` once to initialize ~/.task."
        )
      end
    end
  end

  -- Plugin data directory (saved views, backups)
  local plugin_data = vim.fn.stdpath("data") .. "/taskwarrior.nvim"
  if vim.fn.isdirectory(plugin_data) == 1 then
    vim.health.ok("Plugin data at " .. plugin_data)
  else
    local rebrand = require("taskwarrior.prefix").rebrand
    vim.health.info(rebrand("Plugin data dir not yet created (will appear on first :TaskSave or apply)"))
  end
end

return M
