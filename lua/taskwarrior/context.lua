-- taskwarrior/context.lua — Taskwarrior context support (tw c12b4cbd).
--
-- `task context work` / `task context none` set a global context in the
-- user's .taskrc; reports honor it automatically. TW 3.x does NOT apply the
-- context to `export`, which is how this plugin reads everything — so the
-- render path injects the active context's read filter itself via
-- M.filter_tokens(). The injected tokens end up in the rendered taskmd
-- header, which keeps the save/apply path consistent with what was rendered
-- (no false external-delete conflicts when a context hides tasks).

local M = {}
local command = require("taskwarrior.command")
local notify = require("taskwarrior.notify")

-- Current context name, or nil when unset.
function M.current()
  local result = command.read({ "_get", "rc.context" })
  if not result.ok then return nil end
  local name = vim.trim(result.output or "")
  -- Context names never contain whitespace — anything else is CLI chatter.
  if name == "" or name:find("%s") then return nil end
  return name
end

-- All defined context names.
function M.list()
  local result = command.read({ "_context" })
  if not result.ok then return {} end
  local out = {}
  for line in (result.output or ""):gmatch("[^\r\n]+") do
    local v = vim.trim(line)
    if v ~= "" and not v:find("%s") then out[#out + 1] = v end
  end
  return out
end

-- Read filter of the named (default: active) context, or nil.
function M.read_filter(name)
  name = name or M.current()
  if not name then return nil end
  local result = command.read({ "_get", "rc.context." .. name .. ".read" })
  local f = result.ok and vim.trim(result.output or "") or ""
  if f == "" then
    -- Contexts defined by TW <2.6 live in rc.context.<name> without .read.
    result = command.read({ "_get", "rc.context." .. name })
    f = result.ok and vim.trim(result.output or "") or ""
  end
  if f == "" then return nil end
  return f
end

-- Tokens to append to a render filter so task buffers honor the active
-- context. Parenthesized so `or`-filters compose with the rest. Skipped for
-- uuid-targeted filters: opening one specific task must never come up empty
-- because a context hides it.
function M.filter_tokens(existing_filter)
  if type(existing_filter) == "string" and existing_filter:find("uuid[%.:=]") then
    return {}
  end
  local f = M.read_filter()
  if not f then return {} end
  local tokens = { "(" }
  for w in f:gmatch("%S+") do tokens[#tokens + 1] = w end
  tokens[#tokens + 1] = ")"
  return tokens
end

local function refresh_all_task_buffers()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.b[b].task_filter ~= nil then
      pcall(function() require("taskwarrior.buffer").refresh_buf(b) end)
    end
  end
end

-- Show the active context and the available ones.
function M.show()
  local cur = M.current()
  local names = M.list()
  local lines = {}
  if cur then
    lines[1] = ("taskwarrior.nvim: context %s (%s)"):format(cur, M.read_filter(cur) or "?")
  else
    lines[1] = "taskwarrior.nvim: no context active"
  end
  if #names > 0 then
    lines[#lines + 1] = "available: " .. table.concat(names, ", ") .. ", none"
  else
    lines[#lines + 1] = "none defined — create one with: task context define work project:work"
  end
  notify("view", table.concat(lines, "\n"))
end

--- Fuzzy-pick a context to activate. Lists every defined context with its
--- read filter, marks the active one, and offers "none" to clear plus a
--- "define new" escape hatch so an empty context list is not a dead end.
function M.pick()
  local names = M.list()
  local current = M.current()
  local entries = { { value = "none", label = "none      (clear context)" } }
  for _, name in ipairs(names) do
    entries[#entries + 1] = {
      value = name,
      label = ("%-10s%s"):format(name, M.read_filter(name) or ""),
    }
  end
  entries[#entries + 1] = { value = "\0define", label = "+ define a new context…" }

  require("taskwarrior.pick").select(entries, {
    prompt = "Context:",
    current = current or "none",
  }, function(value)
    if value == "\0define" then return M.define() end
    M.set(value)
  end)
end

--- Define a context. `filter` is a Taskwarrior filter expression; when
--- omitted the user is prompted for it. Prompts for the name too when nil.
function M.define(name, filter)
  local function do_define(n, f)
    n, f = vim.trim(n or ""), vim.trim(f or "")
    if n == "" or f == "" then return end
    if n == "none" then
      notify("error", "taskwarrior.nvim: 'none' is reserved — pick another name",
        vim.log.levels.ERROR)
      return
    end
    local args = { "context", "define", n }
    -- The filter is one CLI argument per token, same as any other filter.
    local parsed = command.parse_args(f)
    if not parsed then
      notify("error", "taskwarrior.nvim: unparseable context filter",
        vim.log.levels.ERROR)
      return
    end
    vim.list_extend(args, parsed)
    local result = command.mutate(args)
    if not result.ok then
      notify("error", "taskwarrior.nvim: context define failed\n" .. (result.output or ""),
        vim.log.levels.ERROR)
      return
    end
    notify("view", ("taskwarrior.nvim: context %s defined (%s)"):format(n, f))
    -- Offer to switch to it right away — defining one you don't then use is
    -- almost never what you meant.
    vim.ui.select({ "Activate now", "Leave inactive" }, {
      prompt = ("Activate context %s?"):format(n),
    }, function(choice)
      if choice == "Activate now" then M.set(n) end
    end)
  end

  if name == nil or vim.trim(name) == "" then
    vim.ui.input({ prompt = "Context name: " }, function(n)
      if not n or vim.trim(n) == "" then return end
      vim.ui.input({ prompt = "Filter (e.g. project:work or +work): " }, function(f)
        do_define(n, f)
      end)
    end)
    return
  end
  if filter == nil or vim.trim(filter) == "" then
    vim.ui.input({ prompt = ("Filter for context %s: "):format(name) }, function(f)
      do_define(name, f)
    end)
    return
  end
  do_define(name, filter)
end

--- Delete a context definition (prompts to pick one when name is omitted).
function M.delete(name)
  local function do_delete(n)
    local result = command.mutate({ "context", "delete", n })
    if not result.ok then
      notify("error", "taskwarrior.nvim: context delete failed\n" .. (result.output or ""),
        vim.log.levels.ERROR)
      return
    end
    notify("view", ("taskwarrior.nvim: context %s deleted"):format(n))
    refresh_all_task_buffers()
  end

  if name and vim.trim(name) ~= "" then return do_delete(vim.trim(name)) end
  local names = M.list()
  if #names == 0 then
    notify("warn", "taskwarrior.nvim: no contexts defined", vim.log.levels.WARN)
    return
  end
  vim.ui.select(names, { prompt = "Delete which context?" }, function(choice)
    if choice then do_delete(choice) end
  end)
end

-- Set (or clear, with "none") the context, then refresh open task buffers.
-- Bare `:TwContext` clears — the common case is "get me out of this
-- context"; use `:TwContext show` for the read-only summary.
function M.set(name)
  name = vim.trim(name or "")
  if name == "" then name = "none" end
  if name == "show" then return M.show() end
  -- `task context none` exits 2 when no context was set ("Context not
  -- unset.") — clearing an already-clear context is a no-op, not an error.
  local ok_codes = name == "none" and { 0, 1, 2 } or nil
  local result = command.mutate({ "context", name }, { ok_codes = ok_codes })
  if not result.ok then
    notify("error", "taskwarrior.nvim: context failed\n" .. (result.output or ""),
      vim.log.levels.ERROR)
    return
  end
  if name == "none" then
    notify("view", "taskwarrior.nvim: context cleared")
  else
    notify("view", ("taskwarrior.nvim: context %s (%s)"):format(
      name, M.read_filter(name) or "?"))
  end
  refresh_all_task_buffers()
end

return M
