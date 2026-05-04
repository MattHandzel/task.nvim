# Easy-feedback flow — design (v1.4.1)

> Goal: when something goes wrong, the friction of reporting it should be
> lower than the friction of working around it. Anyone who hits an error
> can file a complete, diagnosable GitHub issue in under 30 seconds without
> hand-pasting a stack trace.

---

## Current state — and what's broken

`lua/taskwarrior/feedback.lua` already exists and provides `:TaskFeedback`. It's structurally sound but bricked by a default-config bug:

| Symptom | Root cause | Fix |
|---|---|---|
| `:TaskFeedback` no-ops with "feedback is disabled" notify on default install | `feedback_endpoint = false` default → `M.open()` early-returns at `feedback.lua:441–447` regardless of which output the user wants | Default `feedback_endpoint = nil` (omitted, not boolean false). Gate ONLY the "Send to endpoint" choice on the endpoint, not the entire flow. The "Open as GitHub issue" + "Copy to clipboard" paths must work without any endpoint configured. |
| Users don't know `:TaskFeedback` exists | No discoverability | Add a one-shot session-scoped hint when an ERROR notify fires from the plugin: "Press `:TaskFeedback` to report this." Throttled to once per session. |
| Reports lack runtime context | Form template is empty boxes; user has to manually transcribe what happened | Add an auto-filled "Recent log entries" section pulling from a new in-memory ring buffer (last 10 plugin notifications at WARN/ERROR level). |
| User can't easily copy a stack trace from `:messages` into the form | No bridge | Add a `:TaskFeedback last-error` subcommand that prefills the form with the most recent ERROR + its stack trace. |

Practical impact today: msakiart hit issue #2, but `:TaskFeedback` would have refused to open. They had to use the GitHub web UI manually. We need this fixed before launch traffic arrives.

---

## Design

### Three tiers of discoverability

**Tier 1 — Always-available (everyone gets this)**
- `:TaskFeedback` opens the structured form.
- `:TaskFeedback last-error` prefills with the most recent ERROR.
- Optional global keymap `<leader>tF` (configurable; default off so we don't claim leader keys without consent).

**Tier 2 — Context capture (auto, opt-out via config)**
- `lua/taskwarrior/notify.lua` (existing) gains a private ring buffer that captures the last 10 notifications at WARN+ severity.
- Captures only notifications routed through `taskwarrior.notify(msg, level)` — not the global `vim.notify`. We never observe other plugins' notifications.
- Auto-filled into the feedback form's "Recent log entries" section.
- Opt out via `setup({ feedback = { capture_log = false } })`.

**Tier 3 — One-shot session hint (opt-out)**
- The first time `taskwarrior.notify` emits at ERROR severity in a given nvim session, append a one-line hint: "Tip: press `:TaskFeedback last-error` to report this with one click."
- One per session, not one per error. Stored in a module-local boolean.
- Opt out via `setup({ feedback = { hint_on_error = false } })`.

### The form (what the user sees on `:TaskFeedback`)

Markdown buffer named `[taskwarrior.nvim Feedback]`. Pre-filled template:

```markdown
# Report an issue

## What happened?

(describe what you were doing — be specific)


## What did you expect to happen?



## Anything else?

(steps to reproduce, screenshots, links)


---

## Environment (auto-filled — please leave as-is)

```
plugin_version: v1.4.1
nvim_version:   0.10.2
os:             Linux 6.14.0
tw_version:     3.4.2
backend:        lua
task_count:     127
```

## Recent plugin log entries (auto-filled)

```
[14:22:01 WARN] task export: connection refused (taskmd.lua:176)
[14:22:01 WARN] taskmd.lua: returning empty result; falling back to cached
[14:23:14 ERROR] apply: external_modify on UUID abc123 prevented save
                 (apply.lua:45 → buffer.lua:512 → init.lua:217)
```
```

After `:w` on the buffer, `vim.ui.select` prompts:

```
1. Open as GitHub issue (browser)
2. Copy this report to clipboard
3. Send to <feedback_endpoint>            (only shown if endpoint configured)
4. Cancel
```

For "Open as GitHub issue", the body is URL-encoded into `https://github.com/MattHandzel/taskwarrior.nvim/issues/new?title=...&body=...`, opened via `vim.ui.open` (nvim 0.10+) or `xdg-open` fallback.

### `:TaskFeedback last-error` — the launch-week killer feature

The flow that solves the msakiart case:

1. User hits a bug → plugin emits an ERROR notify (e.g. "task export failed: connection refused").
2. Tier 3 hint appears: "Tip: press :TaskFeedback last-error to report this with one click."
3. User runs `:TaskFeedback last-error`.
4. Form opens with:
   - **What happened?** prefilled: "task export failed: connection refused"
   - **Recent log entries** auto-filled with the last 10 entries (the error in context)
   - **Environment** auto-filled
5. User types two sentences in "What did you expect" + "Anything else", saves.
6. Picks "Open as GitHub issue" → browser opens to the prefilled-body issue form on GitHub.
7. They click Submit. Total: ~30 seconds.

---

## Privacy + safety

These rules are non-negotiable. Every send/copy path must obey them.

| Rule | Implementation |
|---|---|
| **No silent send** | Never POST anything without explicit user choice from the post-`:w` prompt. The `feedback_endpoint` only enables the "Send" *option*; the user still has to pick it. |
| **Show the exact payload before send** | The post-`:w` prompt includes a `Preview` view — full pretty-printed JSON of what will be transmitted. (`feedback.lua` already has this — verify still works after the default fix.) |
| **Path scrubbing** | Replace `$HOME` with `~` in stack traces and config paths. Existing `scrub_paths` in `feedback.lua:45` handles this; add tests. |
| **No task descriptions in auto-fill** | The Environment section includes `task_count`, never task contents. The Recent log section captures notify *messages* only — not buffer contents, not task data. |
| **No third-party plugin notifications** | The ring buffer only captures notifications routed through `taskwarrior.notify`. Don't monkey-patch global `vim.notify`. |
| **Opt-out for everything** | All three tiers controllable via `setup({ feedback = { ... } })`. |

---

## Config surface

Add to `config.lua` defaults:

```lua
feedback = {
  -- Enable the in-memory ring buffer that captures the last N
  -- WARN/ERROR notifications for auto-fill. Off → form's "Recent log
  -- entries" section is omitted.
  capture_log = true,
  capture_log_size = 10,

  -- Show one tip per nvim session when an ERROR notify fires.
  hint_on_error = true,

  -- Optional global keymap. Default nil (no global key) — opt-in.
  feedback_key = nil,
},
```

Existing `feedback_endpoint` and `feedback_github_repo` keep their current
positions at the top level, but `feedback_endpoint` defaults change from
`false` to `nil` — the gating logic shifts from "is this != false?" to
"is this a non-empty string?".

---

## Implementation plan (in TDD order, ~2-3 hours)

**Commit 1 — Tests (RED)**
- `tests/lua/spec/feedback_spec.lua`
- Assert: `:TaskFeedback` opens with default config (current bug)
- Assert: form contains all four expected sections
- Assert: ring buffer captures WARN+ but not INFO
- Assert: ring buffer caps at `capture_log_size` (FIFO eviction)
- Assert: `notify` ring buffer is module-private — no global state leak
- Assert: hint fires exactly once per session
- Assert: `last-error` prefills "What happened?" with the most recent ERROR
- Assert: GitHub URL is correctly URL-encoded for body containing newlines, ampersands, unicode
- Assert: path scrubber replaces `$HOME` in arbitrary text
- Assert: opt-out flags actually disable each tier

**Commit 2 — Fix the default-config bug**
- Change `feedback_endpoint` default from `false` to `nil`
- Refactor `M.open()` and `handle_save()` so the "no endpoint" path opens the form and offers GitHub-issue + clipboard, only gating the "Send" choice
- Spec turns mostly green

**Commit 3 — Ring buffer + auto-fill**
- New `lua/taskwarrior/notify_log.lua` (or extend existing `notify.lua`)
- `taskwarrior.notify` writes to the ring buffer at WARN+
- `feedback.build_payload()` reads from it for the "Recent log entries" section
- Spec fully green

**Commit 4 — Hint + `last-error` subcommand + keymap**
- `taskwarrior.notify` checks the once-per-session flag and appends the hint string when emitting ERROR
- `:TaskFeedback last-error` subcommand reads the most recent ERROR from the ring buffer and prefills the form
- Optional `feedback_key` registers a global keymap if set
- Spec for these branches

**Commit 5 — README + help doc + CHANGELOG**
- README: new "Reporting bugs" section between Help and Contributing
- doc/taskwarrior.txt: `:TaskFeedback` and `:TaskFeedback-last-error` tags
- CHANGELOG: v1.4.1 entry

---

## Why this beats the alternatives

| Alternative | Why we're not doing it |
|---|---|
| **Full telemetry / opt-in usage stats** | Privacy ratchet, nontrivial infra, irrelevant to the actual bug-reporting friction. The msakiart problem isn't "we need data" — it's "the user couldn't report what they hit." |
| **Monkey-patch global `vim.notify`** | Affects every plugin's notifications. Rude. Unmaintainable. We capture only our own. |
| **Always-on hint on every error** | Spam. Once-per-session is enough — the user remembers the command after seeing it once. |
| **HTTP-only feedback endpoint** | Requires server, requires hosting, requires cost commitment. The GitHub-issue path is hosted by GitHub for free, lives in public, and is what users would paste into a manual issue anyway. |
| **GitHub Issue Forms (`.github/ISSUE_TEMPLATE/*.yml`)** | We already have these. They help if the user reaches GitHub on their own. The point of `:TaskFeedback` is to bridge users from "saw an error in nvim" to "issue submitted on GitHub" without leaving the editor first. |

---

## Open questions for review

1. **Default keymap or no?** I'm proposing `feedback_key = nil` (opt-in). Argument for `<leader>tF` default: discoverability. Argument against: `<leader>` real estate is contentious. Decision lean: nil; we mention it in the README's keymap table with the suggested binding.

2. **Should the hint append to the error notify, or be a separate scheduled notify?** Append risks looking like the hint is part of the error message. Scheduled risks the user dismissing the error before the hint shows. Lean: separate scheduled notify with a 100ms delay so it appears as a distinct line.

3. **Anonymize task counts?** Currently the Environment section sends `task_count: 127`. Some users will be uncomfortable with that. Lean: keep it (low-sensitivity), but bucket to the nearest order of magnitude (`task_count: ~100`) to soften it.

4. **Capture INFO-level notifications?** Currently scoped to WARN+. INFO would catch successful applies and other "things just worked" messages — useful context for "why did it work the first time and break the second?" but more noise than signal in most reports. Lean: WARN+ only.

5. **Bottom-of-buffer feedback shortcut?** Add `[g?]` keymap inside `:Task` buffers that opens `:TaskFeedback` with the current buffer state attached as context (filter, sort, group, line under cursor — but never task contents). Useful for "the renderer broke on my data" reports. Lean: yes, add in commit 4.
