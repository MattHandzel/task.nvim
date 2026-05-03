# r/neovim launch post — buffer-metaphor framing

**Subreddit:** r/neovim
**Flair:** Plugin
**Best slot:** Tuesday 09:00–13:00 ET (highest engagement window per the playbook research)
**Cross-post target:** r/taskwarrior, r/commandline (different framings — see other files in this dir)

---

## Title

```
[Plugin] taskwarrior.nvim — edit your Taskwarrior database like a markdown buffer (oil.nvim semantics)
```

Title rationale: leads with the named-comparison template that's worked repeatedly in this niche (oil.nvim, voil, flemma). 90 chars, fits Reddit's mobile preview without truncation.

---

## Body

I love [oil.nvim](https://github.com/stevearc/oil.nvim)'s premise — your filesystem is a buffer, every Vim motion is a file operation. I wanted that for my todo list, so I built it on top of Taskwarrior.

`:Task` opens your Taskwarrior database as a markdown buffer:

- **`<CR>`** toggles a checkbox → `task done` on save
- **`o`** adds a new task line → `task add` on save
- **`dd`** (or visual-select + `d`) deletes → `task delete` on save
- **`:%s/project:Inbox/project:career/g`** is a real bulk operation
- **`:w`** diffs everything against fresh Taskwarrior state and applies in one round-trip

Every Vim motion is a task op. Every plugin you already use (Telescope, fzf-lua, snacks.nvim, nvim-cmp, lualine, surround, undotree) just works on this buffer because *it is a buffer*.

[hero GIF — replace with the actual gif URL once uploaded]

Some things that took longer than I expected and might matter to you:

- **Conflict-aware save.** If `task add` runs in another window, or your phone syncs, between the time the buffer rendered and the time you `:w`, the new task is preserved instead of clobbered. Same for external `task modify` — fields you didn't touch survive. Six concurrent-edit scenarios are tested against a real `task` binary on every commit.
- **Picker-agnostic.** Telescope is bundled, but the plugin doesn't require it — fzf-lua, snacks, and `vim.ui.select` work too.
- **Pure-Lua hot path.** No per-task shell spawn (the existing markdown plugins freeze Neovim past ~200 tasks because they shell out per row). One batched `task export`, one render pass.
- **Optional Python CLI** (`bin/taskmd`) for scripting and pipelines — not needed for in-editor use.

**Repo:** https://github.com/MattHandzel/taskwarrior.nvim
**Now on awesome-neovim** under Note Taking.

Install with lazy.nvim:

```lua
{
  "matthandzel/taskwarrior.nvim",
  config = function() require("taskwarrior").setup() end,
}
```

Feedback (especially on the conflict-aware save behaviour) very welcome — there's a survey-mode `:TaskFeedback` if you'd rather log it from the plugin. v1.4.0 is the first release I'd call "actually polished"; happy to add what you'd need to make it your daily driver.

---

## First-comment install snippet (pin)

> `lazy.nvim` install + minimal config:
> ```lua
> {
>   "matthandzel/taskwarrior.nvim",
>   dependencies = { "nvim-telescope/telescope.nvim" }, -- optional
>   keys = {
>     { "<leader>tt", "<cmd>Task<cr>",    desc = "Tasks" },
>     { "<leader>ta", "<cmd>TaskAdd<cr>", desc = "Quick capture" },
>   },
>   config = function() require("taskwarrior").setup() end,
> }
> ```
> Requires Neovim ≥ 0.9 and Taskwarrior ≥ 2.6 (3.x supported). Run `:checkhealth taskwarrior` after install.

---

## Comment templates (anticipate these questions, have replies ready)

**Q: How is this different from m_taskwarrior_d.nvim?**
> m_taskwarrior_d syncs `- [ ]` checkboxes embedded in your *existing* notes — great if your notes are the primary surface. taskwarrior.nvim gives you a dedicated buffer for the database itself; the perf model is different (one batched `task export` vs. per-task shell spawn) and it handles concurrent writes from external sources.

**Q: Does it work with Taskwarrior 3.x SQLite?**
> Yes. The render path uses `task export` (which works on both 2.x and 3.x); the apply path uses `task modify` / `task add` / `task done` / `task delete`. Verified on both.

**Q: Telescope hard-required?**
> No. Telescope ships as an optional `_extension`. The core works with `vim.ui.select`. fzf-lua and snacks.nvim picker integrations are on the roadmap (issue welcome if you want to drive the design).

**Q: Why a Python CLI?**
> Optional, not required. The in-editor render/save path is pure Lua. `bin/taskmd` exists so you can `taskmd render | grep | fzf` from a shell or run automation outside Neovim. Zero non-stdlib Python deps.

**Q: How safe is `:w`?**
> By default the plugin copies your `~/.task` directory to `stdpath("data")/taskwarrior.nvim/backups/<timestamp>/` before any apply (10 most recent kept). The CLI also refuses to apply a file with a missing/malformed header unless you pass `--force`. None of this replaces an external backup, but it covers the "I hand-wrote a file and it marked everything done" failure mode.

---

## Anti-patterns to avoid in the post

- Don't use the `[OC]` flair — `[Plugin]` is the convention
- Don't post on Friday (low engagement) or weekends (different audience, mostly noise)
- Don't post-and-ghost — first 4 hours of comments determine the upvote ratio. Reply to every technical question with a code link
- Don't repost within 90 days, even with new features
- Don't @ Folke / TJ / Maria Solano / echasnovski in the post body — looks spammy. They'll find it organically if it's worth finding
- Don't claim "production ready" — say "v1.4, 480+ tests, feedback welcome"
