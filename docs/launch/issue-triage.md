# Open issue triage + fix plan — 2026-05-02

## Inventory

Two open issues on `MattHandzel/taskwarrior.nvim`:

| # | Title | Author | Type | Real severity |
|---|---|---|---|---|
| [#1](https://github.com/MattHandzel/taskwarrior.nvim/issues/1) | Task cmd is conflict with Shatur/neovim-tasks | cxwx | enhancement | Medium — affects users with overlapping plugins |
| [#2](https://github.com/MattHandzel/taskwarrior.nvim/issues/2) | Tutorial? | mmsaki / msakiart | enhancement (filed) **+ bug (in comment)** | **HIGH** — comment hides a crash on missing `task` binary |

Issue #2 is actually two issues. The headline ask is for a tutorial; the follow-up comment shows a raw `E475: Invalid value for argument cmd: 'task' is not executable` Vim trace from the quick-capture path. **That's a launch-blocking first-touch UX bug** — anyone who installs without Taskwarrior on PATH gets an unintelligible stack trace instead of a clear "install Taskwarrior" message.

## Priority order

1. **#2 crash bug** (HIGH, launch-blocking) — ship today
2. **#2 tutorial** (medium) — needed before the r/neovim post; new users from launch traffic will hit the same gap
3. **#1 command conflict** (medium-low) — has a one-line stopgap; the proper fix can ship in v1.4.2

---

## Fix #1: graceful failure when `task` binary is missing

### Root cause

`lua/taskwarrior/taskmd.lua:172` defines `run(argv)` as a thin `vim.fn.system` wrapper. It checks `vim.v.shell_error` *after* the call but doesn't check `vim.fn.executable("task")` *before* it. When `task` is missing, `vim.fn.system` raises `E475: Invalid value for argument cmd` from inside `vim.schedule`, which produces the Vim-level stack trace msakiart pasted (no friendly message, looks like a plugin bug).

The `health.lua:13–24` check correctly reports the missing binary, but `:checkhealth` is opt-in — most new users won't run it.

### Fix

Two layers, both small:

**Layer A — make `run()` defensive.** Modify `lua/taskwarrior/taskmd.lua:172` to short-circuit when the binary isn't on PATH:

```lua
local _task_checked, _task_available = false, false
local function run(argv)
  if not vim or not vim.fn then
    error("taskmd.lua requires the vim global (must run inside neovim)")
  end
  if not _task_checked then
    _task_available = vim.fn.executable("task") == 1
    _task_checked = true
  end
  if not _task_available then
    return "", 127, "taskwarrior.nvim: `task` not found on PATH. Install Taskwarrior (https://taskwarrior.org) and ensure `task` is on PATH, then :checkhealth taskwarrior."
  end
  local out = vim.fn.system(argv)
  return out, vim.v.shell_error
end
```

Then wherever `run()` callers exist, surface the third return as a `vim.notify(..., vim.log.levels.ERROR)` instead of letting raw output propagate. Need to update at minimum: `taskmd.tw_add`, `taskmd.tw_modify`, `taskmd.tw_done`, `taskmd.tw_delete`, plus the export path that backs `:Task`.

**Layer B — startup-time check.** In `plugin/taskwarrior.lua`, after the `nvim-0.9` check, add:

```lua
if vim.fn.executable("task") ~= 1 then
  vim.notify(
    "taskwarrior.nvim: Taskwarrior CLI not found on PATH. " ..
    "Install from https://taskwarrior.org, then run :checkhealth taskwarrior. " ..
    "Plugin commands are registered but will no-op until the binary is available.",
    vim.log.levels.WARN
  )
end
```

This means users see a single clear warning at startup instead of a crash on first `:TaskAdd`. Layer A still matters for the case where Taskwarrior is uninstalled *after* nvim launches.

### Test bar

Per `CLAUDE.md` verification rules: must be e2e-tested. Add a spec to `tests/e2e/spec/` that runs nvim with `PATH=/dev/null/no-task:$PATH` (or moves the seeded `task` aside), invokes `:TaskAdd`, and asserts:
- No Vim error trace appears
- A `vim.notify` ERROR with the expected message fires
- Plugin doesn't crash; `:q!` exits cleanly

### Effort: 30–60 min including the e2e test.

---

## Fix #2a: tutorial doc

### What msakiart actually wants

Quote: *"Can you do a quick tutorial I want to try it but wish if I could learn how you use it yourself."*

Two readings: (a) written tutorial, (b) video. Written ships today; video is a longer commitment. Ship the written one now and acknowledge the video ask separately.

### Fix

Create `docs/tutorial.md` — a 10-minute walkthrough structured as "first session with the plugin":

1. **Install + verify** (`:checkhealth taskwarrior`)
2. **Your first task** — `:TaskAdd`, type `Try taskwarrior.nvim project:learning`, press Enter, watch it appear in `:Task`
3. **Edit a task** — open `:Task`, navigate to the line, change `priority:M` to `priority:H` by typing, `:w`, watch the confirmation dialog
4. **Mark done** — `<CR>` on a line, `:w`, see the task disappear from pending
5. **Bulk-edit** — visual-select 3 lines, `:s/project:Inbox/project:work/`, `:w`
6. **Filter** — `:TaskFilter project:work`, `:TaskGroup project`, `:TaskSort due+`
7. **Save the view** — `:TaskSave morning`, then later `:TaskLoad morning`
8. **Quick capture** — leave any buffer, `<leader>ta`, type a task, Enter, you're back where you were
9. **Visualize** — `:TaskBurndown`, `:TaskTree`, `:TaskCalendar`
10. **Clean up** — undoing a save with `:TaskUndo`

Each step has the exact keystrokes, the expected result, and a "what just happened" sentence linking to the relevant `:help taskwarrior-<topic>` tag. Link from the README's existing "Help" section.

### Effort: 60–90 min for a careful, cross-linked tutorial.

### Follow-on (asynchronous, not blocking the launch)

Reply to issue #2 with the doc link and offer: *"A video walkthrough is also planned — would you prefer (a) a 5-min "first 10 minutes with the plugin" overview, or (b) a longer "my actual daily workflow" stream-style?"* Lets msakiart self-select; the answer also informs which YouTuber pitch to lead with (Linkarzu prefers (b), typecraft prefers (a)).

---

## Fix #3: command-name conflict with Shatur/neovim-tasks (#1)

### Root cause

`plugin/taskwarrior.lua:38` and `lua/taskwarrior/commands.lua:7` both register `:Task`. `Shatur/neovim-tasks` also registers `:Task` (with subcommands like `:Task start`, `:Task cancel`). Whichever plugin loads second has its registration silently overridden — the user doesn't know which one wins.

### Fix — two layers, ship the stopgap immediately, the proper fix in v1.4.2

**Stopgap (5 min, ship today):** in `plugin/taskwarrior.lua`, before `nvim_create_user_command("Task", ...)`, check whether `:Task` already exists and emit a clear warning instead of silently colliding:

```lua
local existing = vim.api.nvim_get_commands({})
if existing.Task and existing.Task.definition ~= "" then
  vim.notify(
    "taskwarrior.nvim: :Task already registered by another plugin (likely Shatur/neovim-tasks). " ..
    "Set `vim.g.taskwarrior_command_prefix = 'Tw'` in your config (before plugin load) to use :Tw* instead. " ..
    "See https://github.com/MattHandzel/taskwarrior.nvim/issues/1",
    vim.log.levels.WARN
  )
end
```

This doesn't fix the conflict but makes it visible and tells the user how to opt out. Closes the "silent overwrite" failure mode.

**Proper fix (~2 hours, v1.4.2):** add a configurable command prefix.

- Add `command_prefix = "Task"` to `lua/taskwarrior/config.lua` defaults
- Read `vim.g.taskwarrior_command_prefix` at the top of `plugin/taskwarrior.lua` (since the plugin file runs before `setup()`); use it for the lazy `:Task` registration. Default to `"Task"`
- Refactor `lua/taskwarrior/commands.lua` to read `config.options.command_prefix` and prefix every command name (`Task → <prefix>`, `TaskFilter → <prefix>Filter`, etc.). 40 commands to refactor — mechanical
- Update `doc/taskwarrior.txt` help tags
- Update README install section with "If you already use Shatur/neovim-tasks, set `vim.g.taskwarrior_command_prefix = 'Tw'` *before* loading the plugin"
- E2e test: load plugin with `vim.g.taskwarrior_command_prefix = "Tw"`, verify `:TwAdd` works and `:TaskAdd` doesn't exist

### Effort: 5 min (stopgap) + ~2 hr (proper fix with tests)

### Why not rename outright?

Renaming `:Task*` → `:Tw*` (or similar) by default would break every existing user's keymaps, slash-commands, and muscle memory. Backward-compatibility cost is real. The configurable-prefix path keeps existing users unbroken while letting collision-affected users opt out.

---

## Suggested issue replies (to send after fixes ship)

### To #1 (cxwx)

> Thanks for the report. Shipped a stopgap in v1.4.1 that detects the collision at startup and tells users how to opt out — see [PR #N]. The proper fix (configurable `command_prefix` config option) is queued for v1.4.2. Tracking here: [link to follow-up issue or PR]. If you want to use both plugins right now, set `vim.g.taskwarrior_command_prefix = 'Tw'` in your init *before* the plugin loads.

### To #2 (msakiart)

> Two replies in one:
>
> **The crash you hit** is a real bug — the plugin should have caught the missing `task` binary instead of letting Vim raise `E475`. Fixed in v1.4.1 ([commit/PR link]). Now you'll get a clear "install Taskwarrior" message at startup instead of the trace.
>
> **Tutorial:** added [`docs/tutorial.md`](https://github.com/MattHandzel/taskwarrior.nvim/blob/main/docs/tutorial.md) — a 10-minute walkthrough covering install, first task, edit, mark done, bulk-edit, filter, save view, quick capture, visualizations, undo. Let me know if anything's confusing.
>
> A video walkthrough is also planned — would you prefer a short "first 10 minutes" overview, or a longer "my actual daily workflow" stream? Either way, knowing your preference helps me prioritize.

---

## Sequence

| When | Action |
|---|---|
| Today | Ship Fix #1 (crash) + Fix #3 stopgap (collision warning). Single PR. Tag v1.4.1. Reply to #1 and #2. |
| This week | Ship Fix #2a (tutorial doc). Update README to link it. |
| v1.4.2 (next 2 weeks) | Ship Fix #3 proper (configurable command_prefix). Tag and announce. |
| Async | Record the tutorial video (Linkarzu or typecraft pitch becomes natural follow-up content). |

All three fixes are launch-aligned: they close the failure modes that new traffic from awesome-neovim, the r/neovim post, and the Show HN attempt would otherwise expose.
