-- Minimal, opinionated init.lua for taskwarrior.nvim demo recordings.
-- Keeps the plugin surface visible with no distractions: no plugin manager,
-- no statusline clutter, no telescope popups, just taskwarrior.nvim + basic colors.

vim.opt.termguicolors = true
vim.opt.number = false
vim.opt.relativenumber = false
vim.opt.signcolumn = "no"
vim.opt.laststatus = 0
vim.opt.showcmd = false
vim.opt.showmode = false
vim.opt.ruler = false
vim.opt.cmdheight = 1
vim.opt.cursorline = false
vim.opt.fillchars = { eob = " " }
vim.opt.shortmess:append("I")
vim.opt.updatetime = 100
vim.opt.wrap = false
vim.opt.sidescrolloff = 8

-- Resolve the plugin directory from the script path
local this = debug.getinfo(1, "S").source:sub(2)
local demo_dir = vim.fn.fnamemodify(this, ":h")
local plugin_dir = vim.fn.fnamemodify(demo_dir, ":h:h")
vim.opt.runtimepath:prepend(plugin_dir)

-- Leader before setup so <leader>ta binding takes effect
vim.g.mapleader = " "

require("taskwarrior").setup({
  -- Keep the apply-confirmation picker on. The launch tape now answers it
  -- explicitly (Type "1" Enter after every :w) so the dialog is part of the
  -- demo — viewers see the safety net that protects their real Taskwarrior DB
  -- in everyday use. Flip back to `confirm = false` only if you re-record a
  -- shorter tape that intentionally skips the prompt.
  confirm = true,
  sort = "urgency-",
  group = nil,
})

-- Only auto-open :Tw if no file was given on the command line. The hero
-- and filter-group demos launch with no file and want the instant task view;
-- the quick-capture demo launches with a source file and wants to stay there.
if vim.fn.argc() == 0 then
  vim.schedule(function()
    pcall(vim.cmd, "Tw")
  end)
end
