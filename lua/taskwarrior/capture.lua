local M = {}
local command = require("taskwarrior.command")

-- Omnifunc for the capture window — delegates to task.completion.complete_filter
-- so users get project:, +tag, priority:, field: completions with <Tab>.
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local start = col
    while start > 0 and line:sub(start, start) ~= " " do
      start = start - 1
    end
    return start
  end
  local ok, completion = pcall(require, "taskwarrior.completion")
  if not ok then return {} end
  return completion.complete_filter(base)
end

-- open: open the quick-capture floating window.
-- refresh_fn: callback() to refresh all task buffers after add.
function M.open(refresh_fn)
  local config = require("taskwarrior.config")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = "taskmd"
  vim.bo[buf].omnifunc = "v:lua.require'taskwarrior'._capture_omnifunc"

  local width = config.options.capture_width
      or math.min(80, math.floor(vim.o.columns * 0.6))
  local height = config.options.capture_height or 3
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor(vim.o.lines / 2) - 1,
    style = "minimal",
    border = config.options.border_style or "rounded",
    title = " Task Add ",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.cmd("startinsert")

  -- Color project:/+tag/due:/priority:/UDA fields as they're typed, using the
  -- same highlighter the task buffer uses (tw 14d722e8). Re-runs on every
  -- text change so the coloring tracks what you're typing.
  local ok_buffer, tw_buffer = pcall(require, "taskwarrior.buffer")
  if ok_buffer then
    pcall(tw_buffer.setup_buf_syntax, buf)
  end

  -- Close is always deferred via vim.schedule: cmp's keymap solver (and other
  -- expr-mapping wrappers) can invoke our callbacks from inside a textlock
  -- context where nvim_win_close raises E565. Scheduling moves the close to
  -- the next main loop tick where textlock is released.
  local function do_close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.fn.mode():sub(1, 1) == "i" then
      vim.cmd("stopinsert")
    end
  end

  local function close()
    vim.schedule(do_close)
  end

  local function close_with_confirm()
    vim.schedule(function()
      if config.options.capture_confirm_close ~= false then
        -- Check every line, not just the first: annotation lines below it
        -- are unsubmitted content too.
        local line = vim.api.nvim_buf_is_valid(buf)
            and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            or ""
        if line:match("%S") then
          -- vim.fn.confirm requires a non-textlock context; we're already
          -- inside vim.schedule, so it's safe to call here.
          local choice = vim.fn.confirm("Discard task?", "&Yes\n&No", 2)
          if choice ~= 1 then
            -- Restore insert mode at the line's end so typing resumes naturally.
            if vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_set_current_win(win)
              local last = vim.api.nvim_buf_line_count(buf)
              local last_text = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
              vim.api.nvim_win_set_cursor(win, { last, #last_text })
              vim.cmd("startinsert!")
            end
            return
          end
        end
      end
      do_close()
    end)
  end

  -- Echo the start of what was actually stored so the user can confirm the
  -- right task went through (tw 978fb9d1) — "added task" alone doesn't tell
  -- you whether your fields parsed or the text was mangled.
  local function snippet(text, max)
    max = max or 40
    text = vim.trim(text or "")
    if vim.fn.strchars(text) <= max then return text end
    return vim.fn.strcharpart(text, 0, max) .. "…"
  end

  -- Lines below the first become annotations on the new task (tw 14d722e8).
  -- Set capture_annotations = false to ignore them instead.
  local function annotate_extra_lines(uuid, extra)
    if not uuid or uuid == "" or #extra == 0 then return 0 end
    local done = 0
    for _, text in ipairs(extra) do
      local result = command.mutate({ uuid, "annotate", "--", text })
      if result.ok then
        done = done + 1
      else
        vim.notify("taskwarrior.nvim: annotate failed\n" .. (result.output or ""),
          vim.log.levels.ERROR)
      end
    end
    return done
  end

  local function extra_lines()
    if config.options.capture_annotations == false then return {} end
    if not vim.api.nvim_buf_is_valid(buf) then return {} end
    local all = vim.api.nvim_buf_get_lines(buf, 1, -1, false)
    local out = {}
    for _, l in ipairs(all) do
      local t = vim.trim(l)
      if t ~= "" then out[#out + 1] = t end
    end
    return out
  end

  local function submit(line, extra)
    if not line or line == "" then return end
    extra = extra or {}

    -- Greedy-parse the line so utility:20, project:X, +tag, due:tom etc.
    -- become real fields even when they appear in the middle of free-form
    -- text (e.g. between a sentence and a trailing code block).
    --
    -- IMPORTANT: only fall back to a raw add if PARSING failed. If parsing
    -- succeeded but tw_add couldn't extract a UUID, the task may still have
    -- been created — falling back would create a duplicate with the unparsed
    -- line as the description. (This was the v1.5.0 due:today bug.)
    local ok_m, tm = pcall(require, "taskwarrior.taskmd")
    if ok_m then
      local udas = {}
      local ok_u, list = pcall(tm.tw_udas)
      if ok_u and type(list) == "table" then udas = list end
      local desc, fields = tm.parse_capture(line, udas)
      if desc and desc ~= "" then
        local new_uuid, add_ok = tm.tw_add(desc, fields)
        if new_uuid and new_uuid ~= "" then
          local annotated = annotate_extra_lines(new_uuid, extra)
          local msg = ('taskwarrior.nvim: added "%s"'):format(snippet(desc))
          if annotated > 0 then
            msg = msg .. (" (+%d annotation%s)"):format(
              annotated, annotated == 1 and "" or "s")
          end
          vim.notify(msg)
        elseif add_ok then
          vim.notify(
            "taskwarrior.nvim: added task, but Taskwarrior did not report its UUID; not retrying",
            vim.log.levels.WARN
          )
        else
          vim.notify("taskwarrior.nvim: add failed", vim.log.levels.ERROR)
        end
        if add_ok then refresh_fn() end
        return
      end
    end

    -- Fallback only when parse_capture itself failed (taskmd module missing,
    -- or input was unparseable). Use literal add so the user doesn't lose
    -- their typed content.
    local result = command.mutate({ "add", "--", line })
    if result.ok then
      vim.notify(('taskwarrior.nvim: added (unparsed) "%s"'):format(snippet(line)))
      refresh_fn()
    else
      vim.notify("taskwarrior.nvim: add failed", vim.log.levels.ERROR)
    end
  end

  -- <Tab>/<S-Tab> drive the completion popup
  vim.keymap.set("i", "<Tab>", function()
    return vim.fn.pumvisible() == 1 and "<C-n>" or "<C-x><C-o>"
  end, { buffer = buf, expr = true })
  vim.keymap.set("i", "<S-Tab>", function()
    return vim.fn.pumvisible() == 1 and "<C-p>" or "<S-Tab>"
  end, { buffer = buf, expr = true })

  vim.keymap.set("i", "<CR>", function()
    -- If the popup is visible, accept the selection instead of submitting
    if vim.fn.pumvisible() == 1 then
      return "<C-y>"
    end
    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    local extra = extra_lines()
    -- Defer close + submit to escape any active textlock (nvim-cmp, etc.).
    vim.schedule(function()
      close()
      submit(line, extra)
    end)
    return ""
  end, { buffer = buf, expr = true })

  -- <C-CR> / <C-o> open a new line below for an annotation without
  -- submitting — <CR> stays "submit everything" from any line.
  local function open_annotation_line()
    local last = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, last, last, false, { "" })
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { last + 1, 0 })
    end
    vim.cmd("startinsert!")
  end
  vim.keymap.set("i", "<C-CR>", open_annotation_line, { buffer = buf })
  vim.keymap.set("i", "<C-o>", open_annotation_line, { buffer = buf })

  vim.keymap.set("i", "<Esc>", close_with_confirm, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close_with_confirm, { buffer = buf })
  vim.keymap.set("n", "q", close_with_confirm, { buffer = buf })
end

return M
