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

function M._open_lesson_buffer(idx)
  if not _session then return end

  local buf = vim.api.nvim_create_buf(false, true)  -- listed=false, scratch=true
  local name = "[Tutor lesson " .. tostring(idx) .. "]"
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].bufhidden = "hide"  -- keep buffer alive across window close
                                  -- (cleanup happens on explicit :bw or VimLeave)

  -- Placeholder content. Commit 3 replaces this with real lesson markdown.
  local lines = {
    "# Tutor lesson " .. tostring(idx),
    "",
    "(Lesson content lands in the next commit.)",
    "",
    "Press `:bw` to exit the tutor (everything cleans up automatically).",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  table.insert(_session.buf_ids, buf)

  -- Spec invariant: BufWipeout on a lesson buffer triggers full _cleanup.
  -- Use the session augroup so the autocmd dies cleanly when the session does.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group  = _session.augroup,
    buffer = buf,
    callback = function()
      -- Schedule so we don't run cleanup mid-buffer-deletion (which would
      -- try to delete the buffer that's already in the process of being
      -- deleted, triggering Vim warnings).
      vim.schedule(function() M._cleanup() end)
    end,
  })

  return buf
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

-- Stub for now — commit 3 replaces with the consent-screen flow.
function M.start()
  if _session then
    vim.notify("taskwarrior.tutor: a session is already active; :TaskTutor reset to end it",
      vim.log.levels.WARN)
    return
  end
  M._begin_session()
end

function M.reset()
  M._cleanup()
  M._cleanup_orphans()
end

return M
