-- taskwarrior/notify.lua — category-gated vim.notify wrapper + WARN+ ring buffer.
--
-- Every user-facing notification in taskwarrior.nvim goes through this module.
-- The config option `notifications = { <category> = true|false }` lets users
-- silence specific categories (e.g. `apply = false` in heavy-edit sessions).
--
-- v1.4.1 additions:
--
--   Ring buffer (M.recent) — captures the last N WARN+ notifications so the
--   :TaskFeedback flow can auto-fill "Recent log entries" without forcing
--   the user to copy-paste from :messages. Module-private; only this module's
--   own dispatch path writes to it. Direct vim.notify calls from elsewhere
--   are NOT captured (rule: we never observe other plugins' notifications).
--
-- Usage:
--   local notify = require("taskwarrior.notify")
--   notify("modify", "taskwarrior.nvim: modified")
--   notify("error",  "taskwarrior.nvim: render failed", vim.log.levels.ERROR)
--   local entries = notify.recent()  -- read back the ring buffer

local M = {}

-- ───────────────────────────────────────────────────────────────────────────
-- Ring buffer state (module-private)
-- ───────────────────────────────────────────────────────────────────────────

local DEFAULT_CAP = 10
local _log = {}  -- list of { msg = string, level = int, timestamp = int }

local function ring_cap()
  local ok, config = pcall(require, "taskwarrior.config")
  if ok and config.options
    and config.options.feedback
    and type(config.options.feedback.capture_log_size) == "number" then
    return config.options.feedback.capture_log_size
  end
  return DEFAULT_CAP
end

local function ring_enabled()
  local ok, config = pcall(require, "taskwarrior.config")
  if ok and config.options
    and config.options.feedback
    and config.options.feedback.capture_log == false then
    return false
  end
  return true
end

local function append_to_ring(msg, level)
  if not ring_enabled() then return end
  -- Capture WARN+ only. INFO is noisy (every successful apply, view-load,
  -- etc.) and would balloon the report with no diagnostic signal.
  if level ~= vim.log.levels.WARN and level ~= vim.log.levels.ERROR then
    return
  end
  table.insert(_log, {
    msg       = tostring(msg),
    level     = level,
    timestamp = os.time(),
  })
  -- FIFO eviction at cap.
  local cap = ring_cap()
  while #_log > cap do
    table.remove(_log, 1)
  end
end

-- Public reader. Returns a deep-ish copy so external mutation can't
-- corrupt the buffer (the entries themselves are tables — we copy each).
function M.recent()
  local out = {}
  for _, e in ipairs(_log) do
    table.insert(out, { msg = e.msg, level = e.level, timestamp = e.timestamp })
  end
  return out
end

-- Test hook — clear the buffer. Not used by production code; lets specs
-- start from a clean slate without reloading the module.
function M._reset() _log = {} end

-- ───────────────────────────────────────────────────────────────────────────
-- Notification dispatch
-- ───────────────────────────────────────────────────────────────────────────

local function resolve(level)
  if level == vim.log.levels.ERROR then return "error" end
  if level == vim.log.levels.WARN  then return "warn"  end
  return nil
end

-- Hint state — fired at most once per nvim session. The user sees the
-- pointer to :TaskFeedback once; after that, it's signal-noise.
local _hint_fired = false

local function hint_enabled()
  local ok, config = pcall(require, "taskwarrior.config")
  if not ok then return true end
  if config.options
    and config.options.feedback
    and config.options.feedback.hint_on_error == false then
    return false
  end
  return true
end

-- Test hook: reset the hint flag so successive specs each get the
-- "first ERROR" path. Not for production use.
function M._reset_hint() _hint_fired = false end

local function maybe_append_hint(msg, level)
  if level ~= vim.log.levels.ERROR then return msg end
  if _hint_fired then return msg end
  if not hint_enabled() then return msg end
  _hint_fired = true
  -- Append on a new line so the hint reads as a distinct callout, not a
  -- continuation of the error message itself. Keep it short — users see
  -- it at most once.
  return msg .. "\nTip: press <leader>tF or :TaskFeedback last-error to report this."
end

local function dispatch(cat, msg, level)
  -- Second-arg is the message only when cat is a string category.
  if type(cat) ~= "string" then
    -- Called as notify(msg, level): shift args, resolve category from level.
    level = msg
    msg = cat
    cat = resolve(level)
  end
  level = level or vim.log.levels.INFO

  local ok, config = pcall(require, "taskwarrior.config")
  if ok and config.options.notifications and cat ~= nil then
    local enabled = config.options.notifications[cat]
    if enabled == false then return end
  end

  -- Capture the ORIGINAL message (without hint) into the ring buffer.
  -- The hint is purely UI ergonomics; we don't want it polluting log
  -- entries that get sent in bug reports.
  append_to_ring(msg, level)

  -- Append the hint to the user-visible message only — and only on the
  -- first ERROR per session.
  local out_msg = maybe_append_hint(msg, level)

  vim.notify(out_msg, level)
end

return setmetatable(M, {
  __call = function(_, cat, msg, level)
    return dispatch(cat, msg, level)
  end,
})
