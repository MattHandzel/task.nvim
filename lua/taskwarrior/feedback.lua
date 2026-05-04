-- taskwarrior/feedback.lua — :TaskFeedback command implementation
local M = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local TEMPLATE = [[# taskwarrior.nvim feedback

> Privacy: this report includes plugin version, neovim/taskwarrior versions,
> OS, backend, task count, and a snapshot of safe config keys. It does NOT
> include task descriptions, project names, tags, file paths, hostname, or
> username. The exact JSON payload will be shown for review before sending.

## What happened?


## What did you expect?


## Anything else? (logs, repro, vent — optional)


---
:w to send · :bd! to discard]]

-- Keys allowed in config_summary (server allow-list mirrors this)
local CONFIG_ALLOWLIST = {
  "confirm", "icons", "border_style", "sort", "group", "on_delete", "backend",
  "capture_key", "open_key", "filter_key", "sort_key", "group_key", "project_add_key",
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function get_plugin_version()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_dir = vim.fn.fnamemodify(source, ":h:h:h")
  local out = vim.fn.system("git -C " .. vim.fn.shellescape(plugin_dir) .. " describe --tags --always 2>/dev/null")
  local ver = vim.trim(out or "")
  return ver ~= "" and ver or "unknown"
end

local function scrub_paths(s)
  s = s:gsub("/home/%S+", "~/...")
  s = s:gsub("/Users/%S+", "~/...")
  s = s:gsub("C:\\Users\\%S+", "~/...")
  return s
end

--- Minimal JSON encoder (stdlib-only, no external deps).
--- Handles: nil, boolean, number, string, array-table, dict-table.
local function json_encode(val)
  local t = type(val)
  if val == nil then
    return "null"
  elseif t == "boolean" then
    return tostring(val)
  elseif t == "number" then
    if val ~= val then return "null" end -- NaN
    return tostring(val)
  elseif t == "string" then
    -- Escape special characters
    local escaped = val
      :gsub('\\', '\\\\')
      :gsub('"',  '\\"')
      :gsub('\n', '\\n')
      :gsub('\r', '\\r')
      :gsub('\t', '\\t')
    return '"' .. escaped .. '"'
  elseif t == "table" then
    -- Detect array vs object: array has consecutive integer keys starting at 1
    local is_array = true
    local n = 0
    for k, _ in pairs(val) do
      n = n + 1
      if type(k) ~= "number" or k ~= math.floor(k) then
        is_array = false
        break
      end
    end
    if is_array and n > 0 then
      -- Verify no gaps
      for i = 1, n do
        if val[i] == nil then is_array = false; break end
      end
    end

    if is_array and n > 0 then
      local parts = {}
      for i = 1, n do
        parts[i] = json_encode(val[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(val) do
        if type(k) == "string" then
          table.insert(parts, json_encode(k) .. ":" .. json_encode(v))
        end
      end
      table.sort(parts) -- deterministic key order
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

--- Pretty-print JSON with 2-space indentation.
local function json_pretty(val, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  local inner_pad = string.rep("  ", indent + 1)
  local t = type(val)

  if val == nil or t == "boolean" or t == "number" then
    return json_encode(val)
  elseif t == "string" then
    return json_encode(val)
  elseif t == "table" then
    -- Detect array
    local is_array = true
    local n = 0
    for k, _ in pairs(val) do
      n = n + 1
      if type(k) ~= "number" or k ~= math.floor(k) then
        is_array = false; break
      end
    end
    if is_array and n > 0 then
      for i = 1, n do
        if val[i] == nil then is_array = false; break end
      end
    end

    if is_array and n > 0 then
      local parts = {}
      for i = 1, n do
        parts[i] = inner_pad .. json_pretty(val[i], indent + 1)
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    else
      local parts = {}
      for k, v in pairs(val) do
        if type(k) == "string" then
          table.insert(parts, inner_pad .. json_encode(k) .. ": " .. json_pretty(v, indent + 1))
        end
      end
      table.sort(parts)
      if #parts == 0 then return "{}" end
      return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
    end
  end
  return "null"
end

--- URL-encode a string for use in a query parameter.
local function url_encode(s)
  s = tostring(s or "")
  s = s:gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", c:byte())
  end)
  return s
end

-- ---------------------------------------------------------------------------
-- Buffer parsing
-- ---------------------------------------------------------------------------

--- Parse the feedback buffer lines into section texts.
--- Returns: { what_happened, expected, other }
local function parse_buffer(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sections = {}
  local current_key = nil
  local current_lines = {}

  for _, line in ipairs(lines) do
    local header = line:match("^## (.+)$")
    if header then
      if current_key then
        sections[current_key] = vim.trim(table.concat(current_lines, "\n"))
      end
      -- Normalize header to a key
      if header:match("^What happened") then
        current_key = "what_happened"
      elseif header:match("^What did you expect") then
        current_key = "expected"
      elseif header:match("^Anything else") then
        current_key = "other"
      else
        current_key = nil
      end
      current_lines = {}
    elseif current_key then
      -- Stop collecting at the horizontal rule
      if line == "---" then
        sections[current_key] = vim.trim(table.concat(current_lines, "\n"))
        current_key = nil
        current_lines = {}
      else
        table.insert(current_lines, line)
      end
    end
  end

  if current_key then
    sections[current_key] = vim.trim(table.concat(current_lines, "\n"))
  end

  return {
    what_happened = sections.what_happened or "",
    expected      = sections.expected or "",
    other         = sections.other or "",
  }
end

-- ---------------------------------------------------------------------------
-- Payload builder
-- ---------------------------------------------------------------------------

local function build_payload(report_sections)
  local config = require("taskwarrior.config")
  local opts = config.options

  -- Collect config_summary from allow-list only
  local config_summary = {}
  for _, key in ipairs(CONFIG_ALLOWLIST) do
    local v = opts[key]
    if v ~= nil then
      config_summary[key] = v
    end
  end

  -- Gather client environment
  local nvim_ver = vim.version()
  local nvim_ver_str = string.format("%d.%d.%d", nvim_ver.major, nvim_ver.minor, nvim_ver.patch)

  local uname = vim.loop.os_uname()
  local os_str = (uname.sysname or "unknown") .. "/" .. (uname.machine or "unknown")

  local tw_ver_raw = vim.fn.system("task --version 2>/dev/null")
  local tw_ver = vim.trim((tw_ver_raw or ""):match("^[^\n]+") or "")
  if tw_ver == "" then tw_ver = "unknown" end

  local backend = opts.backend or "lua"

  local task_count_raw = vim.fn.system("task rc.bulk=0 rc.confirmation=off count 2>/dev/null")
  local task_count = tonumber((task_count_raw or ""):match("%d+")) or 0
  -- DP-style bucket so we never share a unique-identifying integer.
  -- See lua/taskwarrior/feedback/privacy.lua + the design doc.
  local task_count_bucket = require("taskwarrior.feedback.privacy").bucket_count(task_count)

  -- Scrub report fields
  local what_happened = scrub_paths(report_sections.what_happened)
  local expected      = scrub_paths(report_sections.expected)
  local other         = scrub_paths(report_sections.other)

  -- Recent WARN/ERROR notifications captured by notify.recent() — gives
  -- the maintainer real diagnostic context without forcing the user to
  -- copy-paste from :messages. Already path-scrubbed at notify time;
  -- we additionally re-scrub here in case any new path showed up.
  local recent = {}
  local ok_notify, notify_mod = pcall(require, "taskwarrior.notify")
  if ok_notify and type(notify_mod.recent) == "function" then
    for _, entry in ipairs(notify_mod.recent()) do
      table.insert(recent, {
        timestamp = entry.timestamp,
        level = entry.level == vim.log.levels.ERROR and "ERROR" or "WARN",
        msg = scrub_paths(entry.msg or ""),
      })
    end
  end

  return {
    version = 1,
    client = {
      plugin_version    = get_plugin_version(),
      nvim_version      = nvim_ver_str,
      os                = os_str,
      tw_version        = tw_ver,
      backend           = backend,
      task_count_bucket = task_count_bucket,
      config_summary    = config_summary,
    },
    report = {
      what_happened = what_happened,
      expected      = expected,
      other         = other,
    },
    recent_log   = recent,
    submitted_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
end

-- ---------------------------------------------------------------------------
-- Send action
-- ---------------------------------------------------------------------------

local function do_send(json_str, endpoint, buf)
  vim.fn.jobstart(
    { "curl", "-sf", "--max-time", "10", "-X", "POST",
      "-H", "Content-Type: application/json",
      "-d", json_str, endpoint },
    {
      stdout_buffered = true,
      stderr_buffered = true,
      on_stdout = function(_, data)
        -- data is a list of lines; join for parsing
        local raw = table.concat(data or {}, "")
        if raw ~= "" then
          local ok, parsed = pcall(vim.fn.json_decode, raw)
          if ok and type(parsed) == "table" and parsed.id then
            vim.schedule(function()
              vim.notify("taskwarrior.nvim: feedback sent — id: " .. parsed.id)
            end)
          end
        end
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if code == 0 then
            pcall(vim.cmd, "bwipeout! " .. buf)
          else
            vim.notify(
              "taskwarrior.nvim: send failed (exit " .. code .. ")",
              vim.log.levels.ERROR
            )
          end
        end)
      end,
    }
  )
end

-- ---------------------------------------------------------------------------
-- GitHub issue fallback
-- ---------------------------------------------------------------------------

-- GitHub silently rejects new-issue prefill URLs longer than ~8KB
-- ("Whoa there! Your request URL is too long."). We pick a conservative
-- ceiling well under that, leaving headroom for the host/path/title.
local GITHUB_URL_LIMIT = 7000

local function build_github_body(payload)
  local c = payload.client or {}
  -- env_block uses task_count_bucket — the field rename in v1.4.1
  -- (was task_count integer). The old field name produced "task_count:
  -- nil" in every report after the rename. Regression test:
  -- tests/lua/spec/feedback_github_url_spec.lua.
  local env_block = table.concat({
    "```",
    "plugin_version:    " .. tostring(c.plugin_version),
    "nvim_version:      " .. tostring(c.nvim_version),
    "os:                " .. tostring(c.os),
    "tw_version:        " .. tostring(c.tw_version),
    "backend:           " .. tostring(c.backend),
    "task_count_bucket: " .. tostring(c.task_count_bucket),
    "```",
  }, "\n")

  return table.concat({
    "## What happened?",
    "",
    payload.report.what_happened,
    "",
    "## What did you expect?",
    "",
    payload.report.expected,
    "",
    "## Anything else?",
    "",
    payload.report.other,
    "",
    "## Environment",
    "",
    env_block,
  }, "\n")
end

local function do_open(url)
  if vim.ui.open then
    vim.ui.open(url)
  else
    vim.fn.system("xdg-open '" .. url .. "'")
  end
end

local function open_github_issue(payload, github_repo)
  local body  = build_github_body(payload)
  local title = "Feedback"
  local base  = "https://github.com/" .. github_repo
             .. "/issues/new?title=" .. url_encode(title)
  local full_url = base .. "&body=" .. url_encode(body)

  if #full_url <= GITHUB_URL_LIMIT then
    -- Body fits in URL — open directly.
    do_open(full_url)
    return
  end

  -- Body too large for GitHub's URL-prefill endpoint. Fall back to
  -- clipboard: copy the full body to clipboard, open the new-issue
  -- page with a placeholder body that tells the user where their
  -- content is. Better than landing on GitHub's "Whoa there!" page.
  pcall(vim.fn.setreg, "+", body)
  pcall(vim.fn.setreg, '"', body)
  local placeholder = table.concat({
    "[Issue body was too long for GitHub's URL prefill (" .. #full_url
      .. " chars > " .. GITHUB_URL_LIMIT .. " ceiling).",
    "",
    "The full report has been copied to your clipboard — please paste",
    "it here, then submit the issue.]",
  }, "\n")
  local fallback_url = base .. "&body=" .. url_encode(placeholder)

  vim.notify(
    "taskwarrior.nvim: feedback body too large for GitHub URL prefill ("
      .. #full_url .. " chars). Full report copied to your clipboard — "
      .. "paste it into the issue body when GitHub opens.",
    vim.log.levels.WARN
  )
  do_open(fallback_url)
end

-- ---------------------------------------------------------------------------
-- Save handler (BufWriteCmd)
-- ---------------------------------------------------------------------------

local function handle_save(buf)
  local config = require("taskwarrior.config")
  local endpoint = config.options.feedback_endpoint
  local github_repo = config.options.feedback_github_repo

  -- No need to recheck endpoint == false here: M.open() refuses to create
  -- the buffer in that case, so handle_save can never be reached with
  -- feedback explicitly disabled. Previously this duplicate check was
  -- gating the post-save flow on `endpoint == false`, but the same was
  -- true at open time — so the check was either redundant (the buffer
  -- couldn't exist) or wrong (would have blocked the GitHub path).

  -- Parse buffer
  local sections = parse_buffer(buf)

  if sections.what_happened == "" then
    vim.notify("taskwarrior.nvim: 'What happened?' is required", vim.log.levels.WARN)
    return
  end

  -- Build payload
  local payload = build_payload(sections)
  local json_str = json_encode(payload)
  local json_display = json_pretty(payload)

  -- Offer choices. The "Send" action is only available when an HTTP
  -- endpoint is configured (default: nil → no Send option). The
  -- GitHub-issue + clipboard paths always work — they're the always-on
  -- fallbacks that fix the "msakiart couldn't even report it" gap.
  local choices = {}
  if type(endpoint) == "string" and endpoint ~= "" then
    table.insert(choices, "Send")
  end
  table.insert(choices, "Open as GitHub issue")
  table.insert(choices, "Copy payload to clipboard")
  table.insert(choices, "Cancel")

  vim.ui.select(choices, {
    prompt = "taskwarrior.nvim feedback — review payload:\n\n" .. json_display .. "\n\nAction?",
  }, function(choice)
    if not choice or choice == "Cancel" then
      vim.notify("taskwarrior.nvim: cancelled")
      return
    end

    if choice == "Send" then
      do_send(json_str, endpoint, buf)

    elseif choice == "Copy payload to clipboard" then
      vim.fn.setreg("+", json_display)
      vim.fn.setreg('"', json_display)
      vim.notify("taskwarrior.nvim: payload copied to clipboard")

    elseif choice == "Open as GitHub issue" then
      if not github_repo then
        vim.notify("taskwarrior.nvim: no feedback_github_repo configured", vim.log.levels.WARN)
        return
      end
      open_github_issue(payload, github_repo)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.open()
  local config = require("taskwarrior.config")

  -- Explicit opt-out: user set feedback_endpoint = false (boolean false,
  -- not nil). Honor that — refuse to open the form.
  --
  -- Default (nil) opens the form; the GitHub-issue and clipboard paths
  -- need no endpoint. The "Send" choice is hidden in handle_save when
  -- endpoint is nil (a non-string can't be POSTed to). Pre-v1.4.1 the
  -- default was `false` and the form was bricked on every install —
  -- this was the bug behind issue #2's "couldn't even report it" gap.
  if config.options.feedback_endpoint == false then
    vim.notify(
      "taskwarrior.nvim: feedback is disabled (feedback_endpoint = false in config)",
      vim.log.levels.WARN
    )
    return
  end

  -- Open new buffer in current window
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()

  -- Buffer settings
  vim.bo[buf].buftype  = "acwrite"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].swapfile = false

  -- Name the buffer (handle pre-existing stale buffer with same name)
  local bname = "[taskwarrior.nvim Feedback]"
  local ok = pcall(vim.api.nvim_buf_set_name, buf, bname)
  if not ok then
    local stale = vim.fn.bufnr(bname)
    if stale ~= -1 and stale ~= buf then
      pcall(vim.api.nvim_buf_delete, stale, { force = true })
      pcall(vim.api.nvim_buf_set_name, buf, bname)
    end
  end

  -- Pre-fill template
  local template_lines = vim.split(TEMPLATE, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, template_lines)
  vim.bo[buf].modified = false

  -- Position cursor on the blank line after "## What happened?"
  for i, line in ipairs(template_lines) do
    if line:match("^## What happened%?") then
      -- Move to 2 lines below the header (the blank line after it)
      vim.api.nvim_win_set_cursor(0, { i + 1, 0 })
      break
    end
  end

  -- BufWriteCmd: intercept :w and run our save flow
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      handle_save(buf)
    end,
  })

  -- q to discard
  vim.keymap.set("n", "q", function()
    vim.cmd("bwipeout!")
  end, { buffer = buf, noremap = true, silent = true })
end

-- Open the form prefilled with the most recent ERROR captured by the
-- ring buffer in lua/taskwarrior/notify.lua. The launch-week killer
-- feature: gets a user from "saw an error" to "GitHub issue submitted"
-- in ~30 seconds because they don't have to retype the error.
function M.last_error()
  local ok_notify, notify_mod = pcall(require, "taskwarrior.notify")
  local last
  if ok_notify and type(notify_mod.recent) == "function" then
    for _, e in ipairs(notify_mod.recent()) do
      if e.level == vim.log.levels.ERROR then last = e end
    end
  end

  -- Open the form first so the user has a buffer to land in even when
  -- there's no recorded error (defensive; e.g. if they ran the command
  -- before any errors fired).
  M.open()

  -- Find the buffer we just opened. Match on the unique name.
  local fb_buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find("taskwarrior.nvim Feedback", 1, true) then
      fb_buf = b
      break
    end
  end
  if not fb_buf then return end  -- M.open refused (e.g. opt-out); nothing to prefill

  if not last then return end  -- no error to prefill; user gets the empty form

  -- Locate the "## What happened?" header and insert the error message
  -- two lines below it. Use buf_set_lines so the inserted text is part
  -- of the buffer history (user can :u it).
  local lines = vim.api.nvim_buf_get_lines(fb_buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:match("^## What happened%?") then
      -- The template has a blank line at i+1 (the cursor lands there
      -- in M.open). Replace it with the prefill so the user can edit
      -- in place.
      local prefill = "Auto-captured ERROR: " .. last.msg
      vim.api.nvim_buf_set_lines(fb_buf, i, i + 1, false, { prefill })
      vim.bo[fb_buf].modified = false
      break
    end
  end
end

-- Open the form with `markdown_block` prefilled into the
-- "Anything else?" section. Used by the :Task buffer's `g?` shortcut
-- (lua/taskwarrior/feedback/context.lua does the sanitized capture).
function M.open_with_context(markdown_block)
  M.open()

  local fb_buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find("taskwarrior.nvim Feedback", 1, true) then
      fb_buf = b
      break
    end
  end
  if not fb_buf then return end

  local lines = vim.api.nvim_buf_get_lines(fb_buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:match("^## Anything else") then
      -- Insert the context block on the line directly after the header.
      -- Split into individual lines to preserve markdown formatting.
      local block_lines = vim.split(markdown_block, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(fb_buf, i, i, false, block_lines)
      vim.bo[fb_buf].modified = false
      break
    end
  end
end

-- Test-only exports — let specs poke at internals without spawning real
-- subprocesses or monkey-patching upvalues. Not public API; the leading
-- underscore signals "tests may peek".
M._build_payload      = build_payload
M._build_github_body  = build_github_body
M._open_github_issue  = open_github_issue
M._GITHUB_URL_LIMIT   = GITHUB_URL_LIMIT

return M
