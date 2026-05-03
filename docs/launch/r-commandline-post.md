# r/commandline cross-post — CLI/automation framing

**Subreddit:** r/commandline (~200k subscribers, broader than r/neovim)
**Best slot:** Wednesday or Thursday (don't double-up on Tuesday with r/neovim + r/taskwarrior)
**Goal:** Reach the wider terminal-first audience who may not yet use Taskwarrior at all but loves the workflow story

---

## Title

```
taskmd: a stdlib-only Python CLI that turns your Taskwarrior database into editable markdown (and a Neovim plugin built on top)
```

Title rationale: leads with the CLI rather than the plugin (r/commandline rewards CLI-first framing). Mentions stdlib-only as a credibility signal (no `pip install` rabbit hole). Plugin is the secondary hook for the Vim crowd.

---

## Body

If you use Taskwarrior, you can now do this from any shell:

```bash
$ taskmd render project:Inbox --sort=due+
- [ ] Triage the new auth ticket due:2026-05-03 +bug
- [ ] Reply to the design RFC due:2026-05-04 priority:H
- [ ] Refactor session middleware project:Inbox

$ taskmd render --group=project | head -20
## Inbox

- [ ] Triage the new auth ticket
- [ ] Reply to the design RFC
...

$ taskmd apply tasks.md --dry-run    # preview changes as JSON
$ taskmd apply tasks.md              # commit them
```

It's a single Python file (`bin/taskmd`), stdlib only, no `pip install` anywhere. Drop it in your `$PATH`, give it a markdown file with checkbox-style tasks, and it round-trips through `task add` / `task modify` / `task done` / `task delete`.

The fun part: the markdown is the database view. Every Taskwarrior field is a literal token in the line:

```
- [ ] Fix login bug project:Work priority:H due:2026-04-01 +urgent +backend
- [x] Already done
```

Vim/Emacs/VSCode/whatever — edit the file with your normal tools, then `taskmd apply` to sync. UUIDs are tracked in HTML comments so cut/paste doesn't corrupt anything; the apply step verifies a file header before touching your DB so you can't accidentally `taskmd apply README.md` and mark every pending task done.

There's also a Neovim plugin built on the same parser if you want it as a buffer with `<CR>`-to-toggle, `o` to add, `dd` to delete, `:w` to apply: https://github.com/MattHandzel/taskwarrior.nvim

A few things that took longer than I expected and might matter to you:

- **Conflict-aware apply.** The CLI re-runs `task export` on apply and diffs your edits against current state — so a `task add` from another shell between render and apply doesn't get clobbered. Same for external `task modify` adding fields.
- **Backups by default.** The Neovim plugin copies `~/.task` to `stdpath('data')/taskwarrior.nvim/backups/` before each save, 10 most recent kept. The CLI requires an explicit header in the file you're applying as a "yes I meant this file" check.
- **480+ tests.** Python CLI test suite + Lua plugin suite + an end-to-end suite that drives every feature against a real `task` binary in a temp `TASKDATA`.

Useful for: editing tasks on a flight (offline edit a markdown file, apply later), piping rendered tasks through `grep`/`fzf`/`gum`, scripting bulk operations, integrating with non-vim editors, or just having a sane plaintext view of your task DB.

Repo (MIT, Python ≥ 3.8, Taskwarrior 2.6+ or 3.x): https://github.com/MattHandzel/taskwarrior.nvim
The CLI is at `bin/taskmd` and works standalone (no Neovim required).

---

## Anticipated questions

**"Why not contribute this to Taskwarrior itself?"**
> Two reasons: (1) Taskwarrior is C++ and adding a Python markdown bridge upstream would be a bigger ask than maintaining it as a sibling tool, (2) the parser also has to handle Vim buffer states (concealed UUIDs, vim-mode edits) that don't belong in upstream Taskwarrior. If anyone from the GothenburgBitFactory team is reading and disagrees, I'd love to talk.

**"Can it work without Taskwarrior?"**
> No — Taskwarrior is the source of truth. The plugin/CLI is a view + apply layer. If you want pure-markdown task lists, [todo.txt](http://todotxt.org/) or [dstask](https://github.com/naggie/dstask) are better fits.

**"What's the perf like?"**
> Render path is one batched `task export` (a single subprocess) and a single-pass parser. ~80ms for 5k tasks. Apply path is per-changed-task `task <verb>`, so apply latency scales linearly with the number of edits — usually invisible (sub-second) unless you're applying hundreds of changes in one save.

**"todo.txt vs Taskwarrior + this?"**
> todo.txt has the elegance of "the file is the database." Taskwarrior has recurrence, urgency formulas, hooks, custom fields, and a real query language. This plugin is for people who want both.

---

## Things to skip in this sub

- Don't lead with "Neovim" in the title — r/commandline has a sizable Emacs/Helix/VSCode crowd
- Don't paste the same body as r/neovim — different audience, different angle
- Don't post screenshots of Vim-specific UI in the top of the post — show shell output
- Don't omit the "stdlib only" claim — it's the single biggest trust signal in this sub
