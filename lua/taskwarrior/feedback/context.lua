-- lua/taskwarrior/feedback/context.lua
--
-- Buffer-context capture for the `g?` shortcut inside :Task buffers.
-- When the user hits g? inside a rendered task buffer, we snapshot the
-- relevant rendering state (filter / sort / group) plus a sanitized
-- window of lines around the cursor, and prefill the feedback form's
-- "Anything else?" section with a markdown-formatted block.
--
-- The privacy contract: every captured task line is run through
-- feedback.privacy.scrub_task_line, so structural Taskwarrior tokens
-- survive verbatim while free-form description content gets `a`-fied.
-- The user reviews the form before any send/copy action, so they can
-- always redact further if the auto-scrub missed something.

local privacy = require("taskwarrior.feedback.privacy")

local M = {}

-- Window radius around cursor — total captured lines is roughly 2*RADIUS+1.
-- 25 each side gives ~50 lines, enough to reproduce most layout bugs
-- without flooding the report.
local CONTEXT_RADIUS = 25

-- Read a buffer-local var or fall back to a placeholder string. Buffer-
-- local vars are set by the renderer (see lua/taskwarrior/buffer.lua's
-- post-render hook) so the context capture has authoritative values.
local function bvar(buf, name)
  local ok, val = pcall(function() return vim.b[buf][name] end)
  if not ok or val == nil or val == "" then return "<unknown>" end
  return tostring(val)
end

function M.capture(buf, cursor_lnum)
  buf = buf or vim.api.nvim_get_current_buf()
  cursor_lnum = cursor_lnum or vim.api.nvim_win_get_cursor(0)[1]

  local total = vim.api.nvim_buf_line_count(buf)
  local lo = math.max(1, cursor_lnum - CONTEXT_RADIUS)
  local hi = math.min(total, cursor_lnum + CONTEXT_RADIUS)
  -- nvim_buf_get_lines is 0-indexed, end-exclusive.
  local raw = vim.api.nvim_buf_get_lines(buf, lo - 1, hi, false)

  local scrubbed = {}
  for _, line in ipairs(raw) do
    table.insert(scrubbed, privacy.scrub_task_line(line))
  end

  return {
    filter = bvar(buf, "taskwarrior_filter"),
    sort   = bvar(buf, "taskwarrior_sort"),
    group  = bvar(buf, "taskwarrior_group"),
    cursor_lnum = cursor_lnum,
    line_range  = { lo, hi },
    lines  = scrubbed,
  }
end

-- Render a snap into a markdown block ready to drop into the feedback
-- form's "Anything else?" section. Plain markdown so `:TaskFeedback`'s
-- buffer (filetype=markdown) renders it cleanly.
function M.format(snap)
  local out = {
    "Buffer context (sanitized — task descriptions scrambled to `a`,",
    "Taskwarrior tokens preserved verbatim):",
    "",
    "    filter:       " .. tostring(snap.filter or "<unknown>"),
    "    sort:         " .. tostring(snap.sort   or "<unknown>"),
    "    group:        " .. tostring(snap.group  or "<unknown>"),
  }
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
