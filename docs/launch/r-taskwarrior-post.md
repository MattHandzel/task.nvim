# r/taskwarrior cross-post — markdown-sync framing

**Subreddit:** r/taskwarrior (small but exact-audience)
**Best slot:** Same Tuesday as the r/neovim post (different framing avoids the cross-post detection that punishes identical posts on multiple subs)
**Goal:** Reach Taskwarrior power-users who don't necessarily live in r/neovim

---

## Title

```
I built a Neovim plugin that lets you edit Taskwarrior tasks as a markdown buffer — feedback wanted
```

Title rationale: lead with "I built" (Reddit prefers builder-first stories), name the integration up front, end with an explicit ask. No bracketed flair tag — r/taskwarrior is small enough that the convention isn't enforced.

---

## Body

I've been a Taskwarrior user for about three years and a Neovim user for longer, and the thing I always wanted was for `:Task` to just open my pending tasks as a buffer I could edit with normal vim motions. So I built it.

```
:Task                           -- opens all pending tasks as markdown
- [ ] Fix login bug project:Work priority:H due:2026-04-01 +urgent
- [x] Already done!
```

Edit any line. `<CR>` toggles done. `o` adds a new task. `dd` deletes. `:%s/project:Inbox/project:career/g` is a real bulk operation. `:w` diffs everything against fresh `task export` and applies — `task modify` / `task add` / `task done` / `task delete` under the hood, so recurrence, urgency, and hooks all still work.

[hero GIF]

A few Taskwarrior-specific things that mattered to me and might matter to you:

- **All writes go through the `task` CLI**, not direct DB access. You keep recurrence, urgency formula, hooks, undo log, and `task sync`. The plugin doesn't try to reimplement Taskwarrior in Lua.
- **Custom UDA support.** `task _udas` is auto-discovered and serialized inline. Custom urgency coefficients are configurable; you can also drop a Lua function for non-linear urgency (`utility / sqrt(effort)`-style formulas).
- **Conflict-aware save.** If you have `task sync` running on a cron, or you `task add` from another shell while the buffer's open, the next `:w` doesn't clobber the external write. It's diffed in.
- **Backups before apply.** Default-on; copies `~/.task` to `stdpath('data')/taskwarrior.nvim/backups/` before each save. Disable if your data dir is large and you have an external strategy.
- **Optional standalone CLI** (`bin/taskmd`, Python stdlib only). `taskmd render project:Inbox --sort=due+ | head -10`. Useful for shell automation that doesn't want to launch Neovim.

Repo: https://github.com/MattHandzel/taskwarrior.nvim
Compatible with Taskwarrior 2.6+ and 3.x. MIT-licensed.

I also wrote a guided weekly-review (`:TaskReview` walks pending tasks in urgency order, single-key actions for keep/defer/done/modify), an inbox triage view (`:TaskInbox`), and a few visualizations (`:TaskBurndown`, `:TaskTree`, `:TaskCalendar`) — all read directly from Taskwarrior, no extra DB.

If you've tried other Neovim+Taskwarrior plugins (ribelo's, neowarrior, m_taskwarrior_d, taskwiki) and bounced off them — would love to know what didn't fit so I can either build it or tell you why I haven't.

---

## Things to mention if asked

- **vit / taskwarrior-tui comparison:** "I love both. They're full-screen TUIs; this is a buffer in your editor. Use the right tool for the moment."
- **Bugwarrior compatibility:** It works — Bugwarrior writes to Taskwarrior, this plugin reads from Taskwarrior. They don't see each other.
- **Mobile sync:** Taskwarrior 3.x sync works fine; the conflict-aware save means you can have your phone sync mid-edit and it'll merge cleanly.
- **Timewarrior:** Not integrated yet. The `granulation` auto-stop-on-idle feature solves the "left a timer running for 8 hours" bug for the Taskwarrior side; Timewarrior bridge is on the roadmap.

---

## Anti-patterns

- Don't post the same body as the r/neovim cross-post. Reddit's spam filter flags identical text across subs.
- Don't claim "Taskwarrior community has been waiting for this" — it hasn't, and it sounds presumptuous.
- Don't trash other Taskwarrior plugins. Some readers are their authors.
- Don't promise features you haven't built. Roadmap items go in the README, not the launch post.
