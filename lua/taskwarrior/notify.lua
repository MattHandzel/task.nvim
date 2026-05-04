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

  -- Capture into the ring before emitting. This way even category-silenced
  -- notifications would still appear in feedback reports if we ever want
  -- that — but currently we only capture WARN+, which is rarely silenced.
  -- (Order is: silence-check → ring-capture → emit. Silenced messages do
  -- not reach the ring, by design.)
  append_to_ring(msg, level)

  vim.notify(msg, level)
end

return setmetatable(M, {
  __call = function(_, cat, msg, level)
    return dispatch(cat, msg, level)
  end,
})
