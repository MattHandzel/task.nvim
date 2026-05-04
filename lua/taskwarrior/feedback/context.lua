-- lua/taskwarrior/feedback/context.lua
--
-- Buffer-context capture for the `g?` shortcut inside :Task buffers.
-- When the user hits g? inside a rendered task buffer, we snapshot the
-- relevant rendering state (filter / sort / group) plus a window of
-- lines around the cursor, and prefill the feedback form's "Anything
-- else?" section with a markdown-formatted block.
--
-- Default mode is SCRUBBED — every captured task line runs through
-- feedback.privacy.scrub_task_line, so structural Taskwarrior tokens
-- survive verbatim while free-form description content gets `a`-fied.
-- The user can also choose ORIGINAL mode (descriptions visible) when
-- they want maximum reproduction fidelity for a rendering bug; the
-- header + form preamble make that mode obvious so they know what
-- they're sharing before they submit.

local privacy = require("taskwarrior.feedback.privacy")

local M = {}

-- Window radius around cursor — total captured lines is roughly 2*RADIUS+1.
-- Default is 8 (so ~17 lines). Was 25 in v1.4.1; reduced after the
-- user reported a g? capture producing a >10KB URL-encoded body that
-- blew past GitHub's URL prefill limit. Power users wanting a wider
-- view can pass opts.radius explicitly.
local DEFAULT_RADIUS = 8

local function bvar(buf, name)
  local ok, val = pcall(function() return vim.b[buf][name] end)
  if not ok or val == nil or val == "" then return "<unknown>" end
  return tostring(val)
end

-- capture(buf, cursor_lnum, opts)
--   opts.scrub    boolean (default true)  — scrub descriptions
--   opts.radius   number  (default DEFAULT_RADIUS) — lines each side
function M.capture(buf, cursor_lnum, opts)
  buf         = buf or vim.api.nvim_get_current_buf()
  cursor_lnum = cursor_lnum or vim.api.nvim_win_get_cursor(0)[1]
  opts        = opts or {}
  local scrub  = (opts.scrub ~= false)  -- default true
  local radius = opts.radius or DEFAULT_RADIUS

  local total = vim.api.nvim_buf_line_count(buf)
  local lo = math.max(1, cursor_lnum - radius)
  local hi = math.min(total, cursor_lnum + radius)
  local raw = vim.api.nvim_buf_get_lines(buf, lo - 1, hi, false)

  local lines = {}
  if scrub then
    for _, line in ipairs(raw) do
      table.insert(lines, privacy.scrub_task_line(line))
    end
  else
    for _, line in ipairs(raw) do table.insert(lines, line) end
  end

  return {
    filter      = bvar(buf, "taskwarrior_filter"),
    sort        = bvar(buf, "taskwarrior_sort"),
    group       = bvar(buf, "taskwarrior_group"),
    cursor_lnum = cursor_lnum,
    line_range  = { lo, hi },
    lines       = lines,
    scrubbed    = scrub,
  }
end

-- format(snap) → markdown block ready to drop under the form's
-- "Anything else?" section. Header advertises which mode was used so
-- the user (and reviewers) can see at a glance whether the block is
-- safe-to-share or contains real content.
function M.format(snap)
  local header
  if snap.scrubbed == false then
    header = {
      "Buffer context (ORIGINAL — task descriptions are visible).",
      "Review this block before submitting; redact anything sensitive.",
    }
  else
    header = {
      "Buffer context (sanitized — task descriptions scrambled to `a`,",
      "Taskwarrior tokens preserved verbatim).",
    }
  end

  local out = {}
  for _, line in ipairs(header) do table.insert(out, line) end
  table.insert(out, "")
  table.insert(out, "    filter:       " .. tostring(snap.filter or "<unknown>"))
  table.insert(out, "    sort:         " .. tostring(snap.sort   or "<unknown>"))
  table.insert(out, "    group:        " .. tostring(snap.group  or "<unknown>"))
  if snap.cursor_lnum then
    table.insert(out, "    cursor_lnum:  " .. tostring(snap.cursor_lnum))
  end
  if snap.line_range and snap.line_range[1] and snap.line_range[2] then
    table.insert(out,
      "    range:        " .. tostring(snap.line_range[1])
                          .. "-" .. tostring(snap.line_range[2]))
  end
  table.insert(out, "")
  table.insert(out, "```")
  for _, l in ipairs(snap.lines or {}) do
    table.insert(out, l)
  end
  table.insert(out, "```")
  return table.concat(out, "\n")
end

return M
