# Show HN post — pure-Lua + conflict-aware-save framing

**Channel:** Hacker News (Show HN)
**Best slot:** Tuesday 08:30 ET
**Trigger condition:** **Only post if the r/neovim post landed >100 upvotes.** Median NV-plugin Show HN scores 2 points; without proof of demand, HN is a coin-flip with downside (a flopped post poisons the well for 60 days). If r/neovim flopped, defer HN by 60 days and rework the angle.

---

## Title

```
Show HN: Taskwarrior.nvim – edit your tasks as a markdown buffer (oil.nvim semantics)
```

Title rationale: HN strips most flair and rewards titles that are *descriptive*, not catchy. The named comparison (oil.nvim) signals the audience to itself. Keep under 80 chars.

---

## Body (the post text — HN limits to ~1500 chars; this is ~1100)

Hi HN — I've been building a Neovim plugin that makes your Taskwarrior database editable like an oil.nvim buffer. Every Vim motion is a task operation: `<CR>` toggles done, `o` adds, `dd` deletes, `:%s///g` bulk-edits, `:w` diffs and applies.

Two technical pieces I'd love feedback on:

**Conflict-aware save.** The buffer is a snapshot of `task export` at render time. On `:w`, the plugin re-exports current state and diffs your edits *against current state*, not against what you saw. So a task `task add`-ed by another shell or your phone between render and save is preserved (not silently clobbered); a field added externally survives; a genuinely-conflicting edit surfaces in the confirmation dialog instead of being silently overwritten. Six concurrent-edit scenarios verified against a real `task` binary on every commit (`tests/e2e/spec/external_changes_spec.lua`).

**Pure-Lua hot path.** The existing markdown-Taskwarrior plugin freezes Neovim past ~200 tasks because it shells out per-task to render. The render path here is one batched `task export` and one Lua pass — renders 5,000 tasks in <100ms on my machine. Apply path goes through `task modify` / `task done` / `task add` / `task delete` so Taskwarrior owns recurrence, urgency, hooks, and undo.

Repo (MIT, Neovim ≥ 0.9, Taskwarrior ≥ 2.6): https://github.com/MattHandzel/taskwarrior.nvim

Optional Python CLI (`bin/taskmd`, stdlib-only) for shell pipelines. 480+ tests across Python, Lua, and a real-CLI e2e suite. Now on awesome-neovim under Note Taking.

Particularly interested in: (1) Lua-side feedback on the diff/merge engine, (2) anyone running large (10k+ task) Taskwarrior dbs who can poke at perf edges, (3) the conflict matrix — there are scenarios I haven't dreamt up yet.

---

## URL field

Use the GitHub repo URL, not a blog post: `https://github.com/MattHandzel/taskwarrior.nvim`

(HN convention: Show HN with `url` field set to the repo, body in `text` field. If you want to link a blog post instead, use `Show HN: <blog>` and reference the repo from inside the post.)

---

## First-4-hours playbook (this is what separates 50-pt and 200-pt HN posts)

The first 4 hours determine whether the post gets traction. Be present and responsive:

- Reply to every technical comment with a code link (line numbers — `lua/taskwarrior/diff.lua#L42-L78` style)
- For "how does it compare to X?" questions, link the `## Compared to other Neovim Taskwarrior plugins` table in the README
- If someone says "doesn't this exist already?" — politely link the README's comparison + acknowledge the prior art
- If a real bug surfaces in the comments, file the issue while the thread is live and link it back ("filed as #N, will fix tonight"). HN respects this
- Avoid defensive replies. If someone hates the markdown-as-interface model, say "fair, here's the design rationale" and link the relevant doc section

---

## Comment templates for predictable questions

**"Why not just use the CLI?"**
> The CLI is great. This is for the workflow where you want to bulk-edit (visual-select 30 tasks, retag, save) — that's three vim motions in a buffer vs. a shell script. The CLI is also bundled (`bin/taskmd render | grep`), so you don't have to choose.

**"How does this compare to m_taskwarrior_d.nvim?"**
> m_taskwarrior_d syncs `- [ ]` checkboxes inside your existing markdown notes. Great if your notes are the primary surface. This plugin gives you a dedicated buffer for the database itself, with a different perf model (batched render vs. per-task shell spawn) and conflict-aware writes from external sources.

**"Is this safe? `:w` runs `task delete`?"**
> Yes, with a backup-before-apply default and a confirmation dialog (also has a live diff-preview mode). The CLI side refuses to apply a file with a missing/malformed header unless you pass `--force`. Backups go to `stdpath("data")/taskwarrior.nvim/backups/`, 10 most recent kept.

**"Why Lua + Python?"**
> Lua for the in-editor hot path (zero deps, fast). Python for the standalone CLI (`bin/taskmd`) so you can pipe rendered tasks through `grep`/`fzf` or automate from shell scripts. Both backends share the same parser/diff/serialize contract via 358 round-trip tests.

**"Taskwarrior 3.x?"**
> Supported. Render uses `task export` (works on 2.x and 3.x); apply uses individual `task modify`/`add`/`done`/`delete` so it inherits TW3's SQLite store transparently.

---

## Things to skip on HN

- Marketing language ("game-changer", "revolutionary"). Just describe.
- Listicles in the post body. HN wants prose with 1-2 technical bones.
- More than 2 paragraphs of feature list. The repo README is for that.
- Self-replies inflating the thread. HN auto-detects.
- Editing the post title after submission — locks engagement immediately.
