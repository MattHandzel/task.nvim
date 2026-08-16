-- taskwarrior/table_view.lua — :TwTable, a vit-style column view (tw 6e9f911d).
--
-- Renders tasks as aligned columns so every data modality (id, urgency,
-- project, priority, due, tags, description, UDAs) is visible at once.
-- Columns come from config.table_columns, so users can add UDA columns,
-- reorder, relabel, resize, or plug in their own formatter.
--
-- Read-only by design: this is a *view*. Editing still happens in the :Tw
-- markdown buffer, which <CR> opens for the task under the cursor.

local M = {}

local views = require("taskwarrior.views")

-- Columns rendered when config.table_columns is unset.
M.DEFAULT_COLUMNS = {
  { field = "id",          label = "ID",   width = 4,  align = "right" },
  { field = "urgency",     label = "Urg",  width = 5,  align = "right" },
  { field = "priority",    label = "P",    width = 1 },
  { field = "project",     label = "Project", width = 14 },
  { field = "due",         label = "Due",  width = 10 },
  { field = "description", label = "Description" },  -- no width = takes the rest
  { field = "tags",        label = "Tags", width = 18 },
}

local function tw_date_to_ymd(val)
  if type(val) ~= "string" then return nil end
  local y, mo, d = val:match("^(%d%d%d%d)(%d%d)(%d%d)T")
  if y then return ("%s-%s-%s"):format(y, mo, d) end
  return val:match("^%d%d%d%d%-%d%d%-%d%d") and val:sub(1, 10) or nil
end

-- Raw cell text for one column of one task. Unknown fields fall through to
-- the task table, so UDA columns work with no extra configuration.
local function cell_value(task, col)
  local field = col.field
  local raw = task[field]
  if col.format then
    local ok, out = pcall(col.format, raw, task)
    if ok then return tostring(out or "") end
    return ""
  end
  if field == "id" then
    return task.id and task.id ~= 0 and tostring(task.id) or ""
  elseif field == "uuid" then
    return (task.uuid or ""):sub(1, 8)
  elseif field == "urgency" then
    return ("%.1f"):format(tonumber(task.urgency) or 0)
  elseif field == "tags" then
    return type(raw) == "table" and table.concat(raw, ",") or ""
  elseif field == "annotations" then
    return type(raw) == "table" and #raw > 0 and ("+" .. #raw) or ""
  elseif field == "status" and task.start then
    return "started"
  elseif field == "due" or field == "scheduled" or field == "wait"
      or field == "entry" or field == "until" or field == "end" then
    return tw_date_to_ymd(raw) or (raw and tostring(raw) or "")
  end
  if raw == nil then return "" end
  if type(raw) == "table" then return table.concat(raw, ",") end
  return tostring(raw)
end

local function pad(text, width, align)
  local w = vim.fn.strdisplaywidth(text)
  if w > width then
    return width > 1 and (vim.fn.strcharpart(text, 0, width - 1) .. "…")
      or vim.fn.strcharpart(text, 0, width)
  end
  local fill = string.rep(" ", width - w)
  if align == "right" then return fill .. text end
  return text .. fill
end

-- Normalize a user column spec (string or table) into the internal form.
local function normalize_columns(cols)
  local out = {}
  for _, c in ipairs(cols or {}) do
    if type(c) == "string" then
      out[#out + 1] = { field = c, label = c:sub(1, 1):upper() .. c:sub(2) }
    elseif type(c) == "table" and c.field then
      out[#out + 1] = {
        field = c.field,
        label = c.label or (c.field:sub(1, 1):upper() .. c.field:sub(2)),
        width = c.width,
        align = c.align,
        format = c.format,
      }
    end
  end
  return out
end

-- Resolve widths: explicit width wins; otherwise size to content, and give
-- any leftover space to the flexible column (the first without a width).
local function resolve_widths(columns, tasks, total_width)
  local widths, flex = {}, nil
  for i, col in ipairs(columns) do
    if col.width then
      widths[i] = col.width
    else
      local w = vim.fn.strdisplaywidth(col.label)
      for _, t in ipairs(tasks) do
        w = math.max(w, vim.fn.strdisplaywidth(cell_value(t, col)))
      end
      widths[i] = w
      if not flex then flex = i end
    end
  end
  if flex then
    local used = 0
    for i, w in ipairs(widths) do
      if i ~= flex then used = used + w + 1 end
    end
    -- Always clamp to the leftover room, never to the content width: a
    -- 300-char description must not push the row past the window edge.
    -- 10 columns is the floor so the cell stays readable when the fixed
    -- columns have eaten the whole budget (the row then overflows by
    -- design rather than rendering an unusable 1-char cell).
    local room = total_width - used - 2
    widths[flex] = math.max(10, math.min(widths[flex], room))
  end
  return widths
end

local function urgency_hl(value)
  local u = tonumber(value) or 0
  if u >= 8 then return "TaskViewUrgHigh" end
  if u >= 4 then return "TaskViewUrgMed" end
  return "TaskViewUrgLow"
end

-- Highlight group for a rendered cell, or nil for default text.
local function cell_hl(col, text, task)
  local f = col.field
  if f == "urgency" then return urgency_hl(task.urgency) end
  if f == "project" then return text ~= "" and "TaskViewProject" or nil end
  if f == "tags" then return text ~= "" and "TaskViewTag" or nil end
  if f == "priority" then
    if text == "H" then return "TaskViewUrgHigh" end
    if text == "M" then return "TaskViewUrgMed" end
    return text ~= "" and "TaskViewUrgLow" or nil
  end
  if f == "due" then
    local ymd = tw_date_to_ymd(task.due)
    if not ymd then return nil end
    if ymd < os.date("!%Y-%m-%d") then return "TaskViewOverdue" end
    if ymd == os.date("!%Y-%m-%d") then return "TaskViewToday" end
    return "TaskViewDate"
  end
  return nil
end

-- Build the buffer content. Returned separately from the window plumbing so
-- tests can assert on the geometry without opening anything.
-- Returns lines, highlights, row_uuids (buffer line index → task uuid).
function M.build(tasks, opts)
  opts = opts or {}
  local config = require("taskwarrior.config")
  local columns = normalize_columns(
    opts.columns or config.options.table_columns or M.DEFAULT_COLUMNS)
  local total = opts.width or vim.o.columns
  local widths = resolve_widths(columns, tasks, total)

  local lines, highlights, row_uuids = {}, {}, {}

  local title = ("taskwarrior.nvim — Table (%s)"):format(opts.filter or "status:pending")
  lines[1] = title
  highlights[#highlights + 1] = { 0, 0, #title, "TaskViewTitle" }

  local header_cells = {}
  for i, col in ipairs(columns) do
    header_cells[#header_cells + 1] = pad(col.label, widths[i], col.align)
  end
  local header = "  " .. table.concat(header_cells, " ")
  lines[#lines + 1] = header
  highlights[#highlights + 1] = { #lines - 1, 0, #header, "TaskViewHeader" }

  local sep = "  " .. string.rep("─", math.max(1, vim.fn.strdisplaywidth(header) - 2))
  lines[#lines + 1] = sep
  highlights[#highlights + 1] = { #lines - 1, 0, #sep, "TaskViewSeparator" }

  for _, task in ipairs(tasks) do
    local parts, col_byte = {}, 2
    local line_hls = {}
    for i, col in ipairs(columns) do
      local raw = cell_value(task, col)
      local text = pad(raw, widths[i], col.align)
      local hl = cell_hl(col, vim.trim(text), task)
      if hl then
        line_hls[#line_hls + 1] = { col_byte, col_byte + #text, hl }
      end
      parts[#parts + 1] = text
      col_byte = col_byte + #text + 1
    end
    lines[#lines + 1] = "  " .. table.concat(parts, " ")
    local li = #lines - 1
    for _, h in ipairs(line_hls) do
      highlights[#highlights + 1] = { li, h[1], h[2], h[3] }
    end
    row_uuids[li] = task.uuid
  end

  if #tasks == 0 then
    lines[#lines + 1] = "  No tasks match this filter."
  end

  lines[#lines + 1] = ""
  local hint = "  <CR> open task in a :Tw buffer · r refresh · q close"
  lines[#lines + 1] = hint
  highlights[#highlights + 1] = { #lines - 1, 0, #hint, "TaskViewHint" }

  return lines, highlights, row_uuids
end

--- :TwTable [filter] — open (or refresh) the table view.
function M.open(filter)
  filter = (filter and filter ~= "") and filter or "status:pending"
  local row_uuids = {}

  local function do_render()
    local tasks = require("taskwarrior.taskmd").shell_export(filter)
    if not tasks then
      require("taskwarrior.notify")("error",
        "taskwarrior.nvim: table view — export failed", vim.log.levels.ERROR)
      return
    end
    local config = require("taskwarrior.config")
    local custom = config.options.custom_urgency
    table.sort(tasks, function(a, b)
      local ua = custom and (tonumber(custom(a)) or 0) or (tonumber(a.urgency) or 0)
      local ub = custom and (tonumber(custom(b)) or 0) or (tonumber(b.urgency) or 0)
      if ua == ub then
        return (a.description or "") < (b.description or "")
      end
      return ua > ub
    end)

    local lines, highlights, uuids = M.build(tasks, { filter = filter })
    row_uuids = uuids
    local bufnr = views._open_scratch(
      "taskwarrior.nvim Table", lines, highlights, do_render)

    vim.keymap.set("n", "<CR>", function()
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      local uuid = row_uuids[row]
      if not uuid then
        require("taskwarrior.notify")("warn",
          "taskwarrior.nvim: no task on this line", vim.log.levels.WARN)
        return
      end
      require("taskwarrior").open("uuid:" .. uuid)
    end, { buffer = bufnr, noremap = true, silent = true,
           desc = "taskwarrior.nvim: open this task in a :Tw buffer" })

    vim.keymap.set("n", "r", do_render, { buffer = bufnr, noremap = true,
      silent = true, desc = "taskwarrior.nvim: refresh the table view" })

    return bufnr
  end

  return do_render()
end

return M
