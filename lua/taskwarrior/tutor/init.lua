-- lua/taskwarrior/tutor/init.lua
--
-- Interactive tutor for taskwarrior.nvim. Runs lessons against a throwaway
-- Taskwarrior database in /tmp; never touches the user's ~/.task or
-- ~/.taskrc. The isolation guarantees are spec'd in
-- tests/lua/spec/tutor_isolation_spec.lua — keep them passing.
--
-- This module deliberately exports a number of `_underscored` symbols. They
-- are NOT public API; they exist so the spec can reach in and verify
-- structural invariants. Other code in the plugin must not call them.
--
-- See lua/taskwarrior/tutor/lessons.lua for lesson content (added in
-- a follow-up commit).

local M = {}

-- ───────────────────────────────────────────────────────────────────────────
-- Single-session state
-- ───────────────────────────────────────────────────────────────────────────
--
-- Module-local. `nil` when no tutor session is active. Kept private so the
-- only ways to mutate it are _begin_session and _cleanup, both of which
-- maintain invariants from the spec.
--
-- Shape:
--   {
--     tmp_dir   = "/tmp/nvim.matt.XXXX_tw_tutor_xyz",
--     taskrc    = "<tmp_dir>/.taskrc",
--     augroup   = <integer>,         -- nvim_create_augroup id
--     buf_ids   = { <bufnr>, ... },  -- lesson buffers (cleaned on session end)
--     term_jobs = { <jobid>, ... },  -- terminal-split jobs (jobstop on cleanup)
--     lesson_idx = 1,
--     started_at = <epoch>,
--   }
local _session = nil

-- Suffix used to mark every tutor temp dir. _scan_orphans matches on this.
-- Must NOT collide with anything the user might create — so we use a long
-- distinctive token.
local TUTOR_DIR_SUFFIX = "_tw_tutor"

-- ───────────────────────────────────────────────────────────────────────────
-- Internals
-- ───────────────────────────────────────────────────────────────────────────

local function safe_delete_dir(path)
  if not path or path == "" then return end
  -- Belt-and-braces: refuse to delete anything that doesn't carry the tutor
  -- suffix, even if some future bug passes a stray path. This is a hard
  -- safety net against ever rm -rf'ing the user's real ~/.task.
  if not path:find(TUTOR_DIR_SUFFIX, 1, true) then
    vim.notify(
      "taskwarrior.tutor: refusing to delete dir without tutor suffix: " .. path,
      vim.log.levels.ERROR
    )
    return
  end
  pcall(vim.fn.delete, path, "rf")
end

-- Build the path to a fresh tutor tmp dir. vim.fn.tempname() is per-nvim-
-- session-unique and lives under nvim's chosen tempdir.
local function new_tmp_dir()
  return vim.fn.tempname() .. TUTOR_DIR_SUFFIX
end

local function write_isolated_taskrc(tmp_dir)
  local rc_path = tmp_dir .. "/.taskrc"
  local lines = {
    "data.location=" .. tmp_dir,
    "hooks=off",
    "verbose=nothing",
    "confirmation=no",
    "bulk=0",
    "json.array=on",
    "news.version=3.4.2",  -- suppress first-run news prompt on TW 3.x
  }
  vim.fn.writefile(lines, rc_path)
  return rc_path
end

-- ───────────────────────────────────────────────────────────────────────────
-- Lifecycle (called by spec; called by lessons.lua in commit 3)
-- ───────────────────────────────────────────────────────────────────────────

-- Create a fresh isolated session. Replaces any prior session (the spec
-- forbids leaking the prior tmp_dir).
function M._begin_session()
  -- Singleton invariant — if a session already exists, clean it up before
  -- starting a new one. The user-facing :TaskTutor handler prompts before
  -- this point; this is the low-level "always safe" entry.
  if _session then M._cleanup() end

  local tmp_dir = new_tmp_dir()
  vim.fn.mkdir(tmp_dir, "p")
  local taskrc = write_isolated_taskrc(tmp_dir)

  local augroup = vim.api.nvim_create_augroup(
    "TaskwarriorTutor_" .. tostring(vim.fn.localtime()),
    { clear = true }
  )

  _session = {
    tmp_dir    = tmp_dir,
    taskrc     = taskrc,
    augroup    = augroup,
    buf_ids    = {},
    term_jobs  = {},
    lesson_idx = 1,
    started_at = os.time(),
  }

  -- Register VimLeavePre cleanup. The autocmd captures the augroup id, so
  -- even if the module is reloaded, the cleanup callback's closure still
  -- holds a ref to the session table being torn down.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function() M._cleanup() end,
  })

  -- Open the first lesson buffer. Until lessons.lua exists, this paints
  -- a placeholder so the spec's BufWipeout test has a real buffer to wipe.
  M._open_lesson_buffer(1)

  return _session
end

-- Idempotent. Safe to call:
--   - twice in a row
--   - before _begin_session
--   - from inside an autocmd that fired during teardown
function M._cleanup()
  if not _session then return end
  local s = _session
  _session = nil  -- nil out FIRST so re-entrant calls (autocmds firing during
                  -- buf_delete) see no session and short-circuit.

  -- 1. Stop terminal jobs (lessons may have spawned a [Tutor shell] split)
  for _, job in ipairs(s.term_jobs or {}) do
    pcall(vim.fn.jobstop, job)
  end

  -- 2. Wipe lesson buffers. Use force=true because these are scratch buffers
  --    we own. pcall because the buffer may already be gone (the BufWipeout
  --    that triggered _cleanup was on one of these).
  for _, buf in ipairs(s.buf_ids or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  -- 3. Clear our autocmd group so stale callbacks can't fire on a dead session.
  if s.augroup then
    pcall(vim.api.nvim_clear_autocmds, { group = s.augroup })
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  end

  -- 4. Delete the temp dir last. safe_delete_dir refuses anything not
  --    matching TUTOR_DIR_SUFFIX as a hardcoded safety net.
  safe_delete_dir(s.tmp_dir)
end

-- Test hook — fires the same callback registered by _begin_session for
-- VimLeavePre, without actually leaving nvim. The spec uses this to verify
-- the cleanup path runs end-to-end without needing :qa!.
function M._simulate_vim_leave()
  if not _session then return end
  -- The registered callback is just M._cleanup; call directly.
  M._cleanup()
end

-- ───────────────────────────────────────────────────────────────────────────
-- Argv prefix — the ONLY way the tutor calls `task`
-- ───────────────────────────────────────────────────────────────────────────

-- Returns { "task", "rc.data.location=<tmp>", "rc.hooks=off", ... }.
-- Lesson code in lessons.lua MUST start every `task` argv with this prefix
-- and then append the verb + args. Tests in commit 3 will assert this is
-- the only entry point so a refactor can't accidentally bypass it.
function M._task_argv_prefix()
  if not _session then
    error("taskwarrior.tutor: no active session — _begin_session first")
  end
  return {
    "task",
    "rc.data.location=" .. _session.tmp_dir,
    "rc.hooks=off",
    "rc.confirmation=no",
    "rc.bulk=0",
    "rc.verbose=nothing",
  }
end

function M._get_session()
  return _session
end

-- ───────────────────────────────────────────────────────────────────────────
-- Lesson buffer (placeholder — real content lands in commit 3)
-- ───────────────────────────────────────────────────────────────────────────

-- Single reusable lesson buffer per session. Created on first call, then
-- repainted as the user advances. Keeps the window layout stable.
local function ensure_lesson_buf()
  if _session.lesson_buf and vim.api.nvim_buf_is_valid(_session.lesson_buf) then
    return _session.lesson_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, "[TaskTutor]")
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = "markdown"
  vim.bo[buf].bufhidden = "hide"

  table.insert(_session.buf_ids, buf)
  _session.lesson_buf = buf

  -- Spec invariant: BufWipeout on a lesson buffer triggers full _cleanup.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group  = _session.augroup,
    buffer = buf,
    callback = function()
      -- Scheduled so we don't run cleanup mid-buffer-deletion.
      vim.schedule(function() M._cleanup() end)
    end,
  })

  return buf
end

-- Helper: open or reuse the [Tutor shell] terminal split. Spawns
-- `bash --norc --noprofile` with TASKDATA + TASKRC env scoped to the
-- tutor temp dir — so user-typed `task add` (no rc flags) hits the
-- sandbox. --norc ensures the user's .bashrc can't override TASKDATA.
local function ensure_terminal_split()
  if _session.term_buf and vim.api.nvim_buf_is_valid(_session.term_buf) then
    -- Already exists; raise it if it's been hidden.
    local wins = vim.fn.win_findbuf(_session.term_buf)
    if #wins == 0 then
      vim.cmd("botright " .. math.floor(vim.o.lines * 0.35) .. "split")
      vim.api.nvim_win_set_buf(0, _session.term_buf)
    end
    return _session.term_buf
  end

  -- Open a split at the bottom; the lesson buffer keeps the top.
  vim.cmd("botright " .. math.floor(vim.o.lines * 0.35) .. "split")
  local term_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, term_buf)
  pcall(vim.api.nvim_buf_set_name, term_buf, "[Tutor shell]")

  -- env merges with parent process env in nvim's termopen — see :h
  -- jobstart-options. So PATH/HOME/etc. inherit; we only override TASKDATA
  -- and TASKRC. --norc/--noprofile keeps user's bashrc from overriding.
  local job = vim.fn.termopen({ "bash", "--norc", "--noprofile" }, {
    env = {
      TASKDATA = _session.tmp_dir,
      TASKRC   = _session.taskrc,
      PS1      = "[tutor] $ ",
    },
    on_exit = function()
      -- Don't cleanup on shell exit — user might exit the shell mid-lesson;
      -- they can always reopen it by retrying the lesson.
    end,
  })

  table.insert(_session.term_jobs, job)
  table.insert(_session.buf_ids, term_buf)
  _session.term_buf = term_buf

  -- Return focus to the lesson window above.
  vim.cmd("wincmd k")
  return term_buf
end

-- Render lesson `idx` into the lesson buffer. Sets up nav keymaps.
local function render_lesson(idx)
  local lessons_mod = require("taskwarrior.tutor.lessons")
  local lesson = lessons_mod.get(idx)
  if not lesson then
    -- No more lessons — graduate.
    M._graduate()
    return
  end

  local buf = ensure_lesson_buf()

  -- Lesson bodies write `:Task`, `:TaskFeedback`, `:TaskTutor reset` etc.
  -- as their literal default. Substitute every `:Task` with the configured
  -- prefix so users running with `command_prefix = "Tw"` (the new v1.4.1
  -- default) see `:Tw`, `:TwFeedback`, `:TwTutor reset`. Same gsub trick
  -- as help.lua. No-op when prefix == "Task" (the legacy override).
  local cfg_prefix = (require("taskwarrior.config").options.command_prefix) or "Task"
  local function rebrand(line) return (line:gsub(":Task", ":" .. cfg_prefix)) end

  -- Build the rendered content: title bar + body + nav line.
  local content = {
    "# " .. lesson.title .. "  (" .. idx .. "/" .. lessons_mod.count() .. ")",
    "",
  }
  for _, line in ipairs(lesson.body) do table.insert(content, rebrand(line)) end
  table.insert(content, "")
  table.insert(content, string.rep("─", 60))
  local nav = "  <CR> check & advance  |  r retry  |  "
  if lesson.skippable or not lesson.validate then nav = nav .. "s skip  |  " end
  nav = nav .. "q quit"
  table.insert(content, nav)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.bo[buf].modifiable = false

  -- Display the buffer in current window if it isn't already visible.
  local wins = vim.fn.win_findbuf(buf)
  if #wins == 0 then
    vim.cmd("tab split")
    vim.api.nvim_win_set_buf(0, buf)
  else
    vim.api.nvim_set_current_win(wins[1])
  end

  -- Set keymaps fresh per render (they're buffer-local; safe to redefine).
  local function nav_map(lhs, fn)
    vim.keymap.set("n", lhs, fn,
      { buffer = buf, nowait = true, silent = true, noremap = true })
  end
  nav_map("<CR>", function() M._advance() end)
  nav_map("r",    function() M._advance() end)  -- same as <CR>: re-validates
  nav_map("s",    function() M._skip() end)
  nav_map("q",    function() M._quit() end)

  _session.lesson_idx = idx

  -- If the lesson needs a shell, ensure it's open. Done after rendering so
  -- focus returns to the lesson window.
  if lesson.setup_terminal then
    ensure_terminal_split()
  end

  -- Auto-advance if skip_if says so (e.g. lesson 2 when task is installed).
  if lesson.skip_if and lesson.skip_if() then
    vim.notify("taskwarrior.tutor: lesson " .. idx .. " skipped (already satisfied)",
      vim.log.levels.INFO)
    vim.schedule(function() M._advance(true) end)
  end
end

-- Public surface for tests + commands.lua entry. Renders a lesson with
-- all the current-session machinery hooked up.
--
-- Note: render_lesson(idx) MAY nil out _session as a side effect — when
-- idx is past the last lesson, render_lesson routes to _graduate which
-- calls _cleanup. So we must not assume _session survives the call.
function M._open_lesson_buffer(idx)
  if not _session then return end
  render_lesson(idx)
  return _session and _session.lesson_buf or nil
end

-- ───────────────────────────────────────────────────────────────────────────
-- Lesson advancement / nav handlers
-- ───────────────────────────────────────────────────────────────────────────

-- Run the current lesson's validator. Returns true if the user can advance.
-- `force` bypasses validation (used by skip_if).
function M._validate_current(force)
  if force then return true end
  if not _session then return false end
  local lesson = require("taskwarrior.tutor.lessons").get(_session.lesson_idx)
  if not lesson or not lesson.validate then return true end

  local api = require("taskwarrior.tutor.lessons").make_api(M)
  local ok, result = pcall(lesson.validate, api)
  if not ok then
    vim.notify("taskwarrior.tutor: validator errored — " .. tostring(result),
      vim.log.levels.ERROR)
    return false
  end
  return result == true
end

function M._advance(force)
  if not _session then return end
  local idx = _session.lesson_idx
  if not M._validate_current(force) then
    local lesson = require("taskwarrior.tutor.lessons").get(idx)
    local hint = lesson and lesson.hint or "Lesson check did not pass."
    vim.notify("taskwarrior.tutor: " .. hint, vim.log.levels.WARN)
    return
  end
  render_lesson(idx + 1)
end

function M._skip()
  if not _session then return end
  local lesson = require("taskwarrior.tutor.lessons").get(_session.lesson_idx)
  if lesson and lesson.validate and not lesson.skippable then
    vim.notify("taskwarrior.tutor: this lesson is not skippable; press <CR> after completing it",
      vim.log.levels.WARN)
    return
  end
  render_lesson(_session.lesson_idx + 1)
end

function M._quit()
  -- Quit is intentional; cleanup immediately. No confirm — the user can
  -- always re-run :TaskTutor to start fresh, and confirms-on-quit are
  -- annoying when the user knows what they want.
  M._cleanup()
  vim.notify("taskwarrior.tutor: ended; temp DB cleaned up", vim.log.levels.INFO)
end

function M._graduate()
  -- Final lesson is "graduation" which has no validator; reaching idx
  -- past the last lesson means the user pressed <CR> on graduation.
  M._cleanup()
  vim.notify(
    -- Use the configured prefix so the suggestion matches whatever
    -- command name actually exists in the user's session.
    "taskwarrior.tutor: tutorial complete! Run :"
      .. (require("taskwarrior.config").options.command_prefix or "Task")
      .. " to start working with your real data.",
    vim.log.levels.INFO
  )
end

-- ───────────────────────────────────────────────────────────────────────────
-- Orphan recovery (post-crash leftover detection)
-- ───────────────────────────────────────────────────────────────────────────

-- Scan nvim's tempname-prefix directory for *_tw_tutor* leftovers.
-- Returns a list of absolute paths. Excludes the active session's tmp_dir
-- so the user is never prompted to clean up the dir they're using right now.
function M._scan_orphans()
  -- vim.fn.tempname() returns a path like /tmp/nvim.user.XXXX/N.
  -- The parent dir is the session-temp root; sibling tw_tutor dirs are
  -- candidates. We scan one level up.
  local probe = vim.fn.tempname()
  local parent = vim.fn.fnamemodify(probe, ":h")
  -- Clean up the probe immediately so it doesn't show in fs.dir.
  pcall(vim.fn.delete, probe)

  local out = {}
  local active = _session and _session.tmp_dir or nil

  -- vim.fn.glob is the most portable. fnameescape avoids issues with the
  -- generated tempname containing characters glob would interpret.
  local pattern = parent .. "/*" .. TUTOR_DIR_SUFFIX .. "*"
  local matches = vim.fn.glob(pattern, false, true)
  for _, p in ipairs(matches or {}) do
    if vim.fn.isdirectory(p) == 1 and p ~= active then
      table.insert(out, p)
    end
  end
  return out
end

function M._cleanup_orphans()
  for _, p in ipairs(M._scan_orphans()) do
    safe_delete_dir(p)
  end
end

-- ───────────────────────────────────────────────────────────────────────────
-- Public API (full UX in commit 3)
-- ───────────────────────────────────────────────────────────────────────────

-- ───────────────────────────────────────────────────────────────────────────
-- Consent screen
-- ───────────────────────────────────────────────────────────────────────────
--
-- Every :TaskTutor invocation shows the consent prompt. The temp dir path
-- differs per session and showing it builds trust — power users can check
-- exactly where the sandbox lives before agreeing.

local function show_verify_buffer()
  -- Each entry in this list becomes one buffer line. nvim_buf_set_lines
  -- rejects any element containing \n (raises "'replacement string' item
  -- contains newlines"), so we cannot use table.concat with newline
  -- separators here — every argv element gets its own line.
  local sample_argv = {
    "task",
    "rc.data.location=" .. (vim.fn.tempname() .. TUTOR_DIR_SUFFIX) .. "  (illustrative — created on consent)",
    "rc.hooks=off",
    "rc.confirmation=no",
    "rc.bulk=0",
    "rc.verbose=nothing",
    "<verb>",
    "<args>",
  }
  local lines = {
    "# taskwarrior.nvim — Tutor verification",
    "",
    "Every `task` command run by the tutor uses this argv prefix:",
    "",
  }
  for _, a in ipairs(sample_argv) do
    table.insert(lines, "  " .. a)
  end
  for _, l in ipairs({
    "",
    "Key isolation flags:",
    "",
    "  * rc.data.location=...   makes Taskwarrior use the throwaway DB",
    "                           in /tmp instead of your ~/.task",
    "  * rc.hooks=off           your ~/.task/hooks/* will NOT run",
    "  * rc.confirmation=no     no interactive prompts",
    "",
    "The [Tutor shell] terminal split (used in some lessons) gets",
    "TASKDATA + TASKRC env scoped to the temp dir, with bash spawned",
    "via `bash --norc --noprofile` so your bashrc cannot override.",
    "",
    "The structural guarantees are tested in",
    "tests/lua/spec/tutor_isolation_spec.lua — see the spec for the",
    "exact invariants.",
    "",
    "Press q or :bd to close this window, then re-run :TaskTutor.",
  }) do table.insert(lines, l) end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype  = "markdown"
  vim.cmd("tab split")
  vim.api.nvim_win_set_buf(0, buf)
  -- :bw (wipe) rather than :bd (unload) — the verify buffer is ephemeral
  -- and shouldn't accumulate in :ls across multiple invocations.
  vim.keymap.set("n", "q", "<cmd>bw<cr>",
    { buffer = buf, nowait = true, silent = true, noremap = true })
end

function M.start()
  if _session then
    vim.ui.select(
      { "Resume current session", "End current and start fresh", "Cancel" },
      { prompt = "taskwarrior.nvim: a tutor session is already active." },
      function(choice)
        if choice == "Resume current session" then
          render_lesson(_session.lesson_idx)
        elseif choice == "End current and start fresh" then
          M._cleanup()
          vim.schedule(function() M.start() end)
        end
      end
    )
    return
  end

  -- Compute the path we WOULD use, just for the consent message. It's
  -- fine if this differs slightly from the actual tmp_dir — vim.fn.tempname()
  -- is monotonic-ish. The user gets the right shape.
  local preview_path = vim.fn.tempname() .. TUTOR_DIR_SUFFIX
  -- Clean up the empty file vim.fn.tempname() may have created.
  pcall(vim.fn.delete, preview_path:gsub(TUTOR_DIR_SUFFIX, ""))

  vim.ui.select(
    {
      "Start the tutor",
      "Show me the exact `task` commands first",
      "Cancel",
    },
    {
      prompt = "Start the interactive Taskwarrior tutorial?\n"
            .. "Sandbox: a throwaway DB will be created near " .. preview_path .. "\n"
            .. "Your real ~/.task and ~/.taskrc will NOT be touched."
    },
    function(choice)
      if choice == "Start the tutor" then
        M._begin_session()
      elseif choice == "Show me the exact `task` commands first" then
        show_verify_buffer()
      end
      -- Cancel / nil → no-op
    end
  )
end

function M.reset()
  M._cleanup()
  M._cleanup_orphans()
end

return M
