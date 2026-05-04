-- lua/taskwarrior/tutor/lessons.lua
--
-- Lesson definitions for :TaskTutor.
--
-- Each lesson is a table:
--   id           string, unique, slug-style.
--   title        string, shown in the lesson header.
--   body         list-of-strings, markdown-flavored, rendered as the lesson
--                content. Use plain ASCII; nerd-font glyphs would break
--                non-NF terminals (the icon-default bug we fixed earlier).
--   setup_terminal     bool, optional. If true, the tutor opens a [Tutor shell]
--                      terminal split with TASKDATA/TASKRC scoped to the temp
--                      dir. The user types task commands in there.
--   validate     function(api) -> boolean, optional.
--                Receives a sandboxed `api` table whose only entry points
--                route through tutor._task_argv_prefix(). A nil validate
--                always passes (useful for read-only lessons).
--   hint         string, optional. Shown when validate returns false.
--   skippable    bool, optional. Shows [s] skip in the nav line.
--   skip_if      function() -> boolean, optional. If returns true, the
--                lesson auto-advances (e.g. lesson 2 skips when task is
--                already installed).
--
-- Lesson authors: the api table is the ONLY sanctioned way to query the
-- tutor DB. Direct `vim.fn.system({"task", ...})` calls will hit the
-- user's real database. The structural-invariant test in
-- tests/lua/spec/tutor_lessons_spec.lua enforces this.

local M = {}

M.lessons = {
  -- ─────────────────────────────────────────────────────────────────────
  {
    id = "welcome",
    title = "Welcome to taskwarrior.nvim",
    body = {
      "# Welcome",
      "",
      "This is a 5-lesson interactive tutorial for Taskwarrior — the",
      "command-line task manager — and the taskwarrior.nvim plugin that",
      "lets you edit your tasks like an oil.nvim buffer.",
      "",
      "## What this tutor does",
      "",
      "  * Teaches the Taskwarrior CLI from scratch (you don't need any",
      "    prior experience).",
      "  * Demonstrates the plugin's added value — bulk edits with vim",
      "    motions, conflict-aware save, picker-agnostic UI.",
      "  * Takes about 20 minutes.",
      "",
      "## Sandbox guarantee",
      "",
      "Every command this tutor runs uses an isolated, throwaway",
      "Taskwarrior database under /tmp. Your real ~/.task and ~/.taskrc",
      "are NEVER touched. When you exit (or :TaskTutor reset), the",
      "temp DB is deleted.",
      "",
      "The ONE exception: the next lesson (Install Taskwarrior) runs",
      "your package manager — and only after you press [Y] to confirm.",
      "",
      "## Navigation",
      "",
      "  <CR>   check this lesson and advance",
      "  r      retry validation (if you're not sure it took)",
      "  s      skip this lesson",
      "  q      quit and clean up everything",
      "",
      "Press <CR> to begin.",
    },
    -- No validation; pure read.
  },

  -- ─────────────────────────────────────────────────────────────────────
  {
    id = "install_taskwarrior",
    title = "Install Taskwarrior",
    skippable = true,
    skip_if = function() return vim.fn.executable("task") == 1 end,
    body = {
      "# Install Taskwarrior",
      "",
      "The plugin is just an editor frontend — it shells out to the `task`",
      "command for every operation. We need that binary on PATH.",
      "",
      "## Detected your environment",
      "",
      "If a supported package manager is detected, you'll see an offer",
      "to install Taskwarrior in a terminal split. We'll show the exact",
      "command before running anything; press <C-c> if you want to abort.",
      "",
      "If `task` is already installed, this lesson auto-skips.",
      "",
      "(Auto-install UI lands in v1.4.1; for now, install manually:)",
      "",
      "  macOS:        brew install task",
      "  Ubuntu/WSL:   sudo apt install -y taskwarrior",
      "  Fedora/Arch:  sudo dnf install -y task   /   sudo pacman -S task",
      "",
      "Then re-run :TaskTutor.",
      "",
      "Press <CR> when `task --version` works in your shell.",
    },
    validate = function(_api)
      return vim.fn.executable("task") == 1
    end,
    hint = "We still don't see `task` on PATH. Open a shell, run `task --version`, then come back.",
  },

  -- ─────────────────────────────────────────────────────────────────────
  {
    id = "cli_add",
    title = "Your first task",
    setup_terminal = true,
    body = {
      "# Add your first task",
      "",
      "Below this lesson, a [Tutor shell] terminal split is open. Inside",
      "that shell, your TASKDATA env points to the tutor's temp DB — so",
      "anything you type there cannot affect your real data.",
      "",
      "## Try this",
      "",
      "In the terminal split, type:",
      "",
      "    task add 'Buy milk'",
      "",
      "You'll see something like `Created task 1.` That's it — Taskwarrior",
      "stored your task. Verify with:",
      "",
      "    task list",
      "",
      "Press <CR> when you've added a task containing the word 'milk'.",
    },
    validate = function(api)
      local tasks = api.export("description.contains:milk")
      return #tasks >= 1
    end,
    hint = "We're looking for a task with 'milk' in its description. " ..
           "Try `task add 'Buy milk'` in the [Tutor shell] terminal.",
  },

  -- ─────────────────────────────────────────────────────────────────────
  {
    id = "cli_metadata_and_done",
    title = "Project, priority, due date — and marking done",
    setup_terminal = true,
    body = {
      "# Metadata and completion",
      "",
      "Taskwarrior tasks can carry rich metadata. Add a project with",
      "`project:`, a priority with `priority:H|M|L`, a due date with",
      "`due:`, and arbitrary tags with `+tagname`.",
      "",
      "## Try this",
      "",
      "In the [Tutor shell]:",
      "",
      "    task add 'Pay rent' project:home priority:H due:tomorrow +bills",
      "",
      "Now look at it with `task list`. See the columns for project,",
      "priority, urgency? Taskwarrior computes urgency automatically",
      "from your metadata.",
      "",
      "Then mark it done. The number on the left of `task list` is the",
      "task ID — replace N with whichever number 'Pay rent' got:",
      "",
      "    task N done",
      "",
      "Press <CR> when 'Pay rent' is in the completed list.",
    },
    validate = function(api)
      local completed = api.export("status:completed description.contains:rent")
      return #completed >= 1
    end,
    hint = "Looking for a *completed* task with 'rent' in its description. " ..
           "If you added it but didn't mark done yet, run `task <id> done`.",
  },

  -- ─────────────────────────────────────────────────────────────────────
  {
    id = "cli_filter_sort",
    title = "Filter and sort",
    setup_terminal = true,
    body = {
      "# Filter and sort",
      "",
      "Taskwarrior's superpower is its query language. Some examples to",
      "try in the [Tutor shell]:",
      "",
      "    task project:home list             # only home-project tasks",
      "    task priority:H list               # only high priority",
      "    task +bills list                   # tagged +bills",
      "    task status:pending count          # how many active tasks?",
      "    task list rc.report.next.sort:due+ # sorted by due date",
      "",
      "Stack them: `task project:home priority.over:M list` shows home",
      "tasks at H priority.",
      "",
      "## Try this",
      "",
      "Add at least one more pending task tagged `+work`:",
      "",
      "    task add 'Send invoices' project:work +work due:friday",
      "",
      "Then run any filter you like and press <CR> when you've added at",
      "least one +work-tagged task.",
    },
    validate = function(api)
      local work_tasks = api.export("+work")
      return #work_tasks >= 1
    end,
    hint = "We need a task tagged +work. Try " ..
           "`task add 'Send invoices' project:work +work` in the [Tutor shell].",
  },

  -- ─────────────────────────────────────────────────────────────────────
  {
    id = "graduation",
    title = "You're ready",
    body = {
      "# Graduation",
      "",
      "You now know enough Taskwarrior to be productive:",
      "",
      "  * `task add '...'` to capture",
      "  * `project:` `priority:` `due:` `+tag` for metadata",
      "  * `task <id> done` to complete",
      "  * Filter+sort with the query language",
      "",
      "## What the plugin adds",
      "",
      "Now you can use taskwarrior.nvim against your REAL data:",
      "",
      "    :Task                        open all pending tasks as a buffer",
      "    <CR> on a line               toggle done",
      "    o                            new task below",
      "    dd                           delete (or done, see config)",
      "    :%s/project:Inbox/career/g   bulk-edit with vim substitutes",
      "    :w                           apply all changes in one round-trip",
      "",
      "The plugin's read path is one batched `task export` — it stays",
      "fast even at 5,000+ tasks. The save path diffs your edits against",
      "fresh Taskwarrior state, so external `task add` from your phone",
      "or another shell between render and save is preserved, never",
      "clobbered.",
      "",
      "## Cleanup",
      "",
      "When you press <CR>, the tutor's temp DB will be deleted. Then",
      "you can run :Task to start working with your real data.",
      "",
      "## Where to go next",
      "",
      "  * :help taskwarrior         full reference",
      "  * :checkhealth taskwarrior  verify your environment",
      "  * :TaskFeedback             report a bug or request a feature",
      "  * https://taskwarrior.org   official Taskwarrior docs",
      "",
      "Press <CR> to graduate.",
    },
    -- No validation; the user just confirms they're done reading.
  },
}

-- Build the sandboxed API a lesson's validate function receives.
-- The ONLY way for lesson code to query Taskwarrior — every entry point
-- routes through tutor._task_argv_prefix(), so isolation is impossible
-- to bypass.
function M.make_api(tutor)
  return {
    -- Run `task <filter...> export` against the tutor DB and return the
    -- parsed JSON array (empty list on error).
    --
    -- The filter is split on whitespace because vim.fn.system(argv) with
    -- a table form treats each element as a SEPARATE argv entry — and
    -- Taskwarrior parses argv element-by-element. Passing
    --   "status:completed description.contains:rent"
    -- as one element would make Taskwarrior see a single weird token and
    -- silently drop both conditions (validator returns 0, lesson stuck).
    -- Bug surfaced in lesson 4 ("Pay rent" → done) before the fix landed.
    export = function(filter)
      local argv = tutor._task_argv_prefix()
      if filter and filter ~= "" then
        for token in tostring(filter):gmatch("%S+") do
          table.insert(argv, token)
        end
      end
      table.insert(argv, "export")
      local out = vim.fn.system(argv)
      if vim.v.shell_error ~= 0 or out == "" then return {} end
      local js = out:find("%[")
      if js and js > 1 then out = out:sub(js) end
      local ok, parsed = pcall(vim.fn.json_decode, out)
      if not ok or type(parsed) ~= "table" then return {} end
      return parsed
    end,
    -- Convenience: total count of pending tasks.
    pending_count = function()
      local argv = tutor._task_argv_prefix()
      table.insert(argv, "status:pending")
      table.insert(argv, "count")
      local out = vim.fn.system(argv):gsub("%s+$", "")
      return tonumber(out) or 0
    end,
  }
end

function M.count() return #M.lessons end
function M.get(idx) return M.lessons[idx] end

return M
