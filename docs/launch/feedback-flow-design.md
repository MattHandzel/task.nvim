# Easy-feedback flow — design (v1.4.1)

> Goal: when something goes wrong, the friction of reporting it should be
> lower than the friction of working around it. Anyone who hits an error
> can file a complete, diagnosable GitHub issue in under 30 seconds without
> hand-pasting a stack trace.

---

## Current state — and what's broken

`lua/taskwarrior/feedback.lua` already exists and provides `:TwFeedback`. It's structurally sound but bricked by a default-config bug:

| Symptom | Root cause | Fix |
|---|---|---|
| `:TwFeedback` no-ops with "feedback is disabled" notify on default install | `feedback_endpoint = false` default → `M.open()` early-returns at `feedback.lua:441–447` regardless of which output the user wants | Default `feedback_endpoint = nil` (omitted, not boolean false). Gate ONLY the "Send to endpoint" choice on the endpoint, not the entire flow. The "Open as GitHub issue" + "Copy to clipboard" paths must work without any endpoint configured. |
| Users don't know `:TwFeedback` exists | No discoverability | Add a one-shot session-scoped hint when an ERROR notify fires from the plugin: "Press `:TwFeedback` to report this." Throttled to once per session. |
| Reports lack runtime context | Form template is empty boxes; user has to manually transcribe what happened | Add an auto-filled "Recent log entries" section pulling from a new in-memory ring buffer (last 10 plugin notifications at WARN/ERROR level). |
| User can't easily copy a stack trace from `:messages` into the form | No bridge | Add a `:TwFeedback last-error` subcommand that prefills the form with the most recent ERROR + its stack trace. |

Practical impact today: msakiart hit issue #2, but `:TwFeedback` would have refused to open. They had to use the GitHub web UI manually. We need this fixed before launch traffic arrives.

---

## Design

### Three tiers of discoverability

**Tier 1 — Always-available (everyone gets this)**
- `:TwFeedback` opens the structured form.
- `:TwFeedback last-error` prefills with the most recent ERROR.
- Optional global keymap `<leader>tF` (configurable; default off so we don't claim leader keys without consent).

**Tier 2 — Context capture (auto, opt-out via config)**
- `lua/taskwarrior/notify.lua` (existing) gains a private ring buffer that captures the last 10 notifications at WARN+ severity.
- Captures only notifications routed through `taskwarrior.notify(msg, level)` — not the global `vim.notify`. We never observe other plugins' notifications.
- Auto-filled into the feedback form's "Recent log entries" section.
- Opt out via `setup({ feedback = { capture_log = false } })`.

**Tier 3 — One-shot session hint (opt-out)**
- The first time `taskwarrior.notify` emits at ERROR severity in a given nvim session, append a one-line hint: "Tip: press `:TwFeedback last-error` to report this with one click."
- One per session, not one per error. Stored in a module-local boolean.
- Opt out via `setup({ feedback = { hint_on_error = false } })`.

### The form (what the user sees on `:TwFeedback`)

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

### `:TwFeedback last-error` — the launch-week killer feature

The flow that solves the msakiart case:

1. User hits a bug → plugin emits an ERROR notify (e.g. "task export failed: connection refused").
2. Tier 3 hint appears: "Tip: press :TwFeedback last-error to report this with one click."
3. User runs `:TwFeedback last-error`.
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
- Assert: `:TwFeedback` opens with default config (current bug)
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
- `:TwFeedback last-error` subcommand reads the most recent ERROR from the ring buffer and prefills the form
- Optional `feedback_key` registers a global keymap if set
- Spec for these branches

**Commit 5 — README + help doc + CHANGELOG**
- README: new "Reporting bugs" section between Help and Contributing
- doc/taskwarrior.txt: `:TwFeedback` and `:TwFeedback-last-error` tags
- CHANGELOG: v1.4.1 entry

---

## Why this beats the alternatives

| Alternative | Why we're not doing it |
|---|---|
| **Full telemetry / opt-in usage stats** | Privacy ratchet, nontrivial infra, irrelevant to the actual bug-reporting friction. The msakiart problem isn't "we need data" — it's "the user couldn't report what they hit." |
| **Monkey-patch global `vim.notify`** | Affects every plugin's notifications. Rude. Unmaintainable. We capture only our own. |
| **Always-on hint on every error** | Spam. Once-per-session is enough — the user remembers the command after seeing it once. |
| **HTTP-only feedback endpoint** | Requires server, requires hosting, requires cost commitment. The GitHub-issue path is hosted by GitHub for free, lives in public, and is what users would paste into a manual issue anyway. |
| **GitHub Issue Forms (`.github/ISSUE_TEMPLATE/*.yml`)** | We already have these. They help if the user reaches GitHub on their own. The point of `:TwFeedback` is to bridge users from "saw an error in nvim" to "issue submitted on GitHub" without leaving the editor first. |

---

## Decisions (post-review)

1. **`<leader>tF` is the default global keymap.** Discoverability wins over leader-key real estate; the user can disable via `setup({ feedback = { feedback_key = false } })`.

2. **Hint appends to the error notify message.** Same notification, two lines:
   ```
   [ERROR] taskwarrior.nvim: task export failed: ...
   Tip: press <leader>tF or :TwFeedback last-error to report this.
   ```
   One per session. Less visually noisy than a second scheduled notify; the user reads the error and the hint together.

3. **Differential-privacy-style bucketing for `task_count`.** Logarithmic-ish buckets, reported as a range string:
   - `0` → `0`
   - `1-2`, `3-5`, `6-10`, `11-25`, `26-100`, `101-500`, `501-2000`, `2001-10000`, `10001+`

   Each bucket is wide enough that it's not unique-identifying. Sent as `task_count_bucket: "26-100"`, never the raw integer. Same approach extended to any future numeric counters (annotation count, project count) before they ship.

4. **WARN+ ring buffer only.** INFO captures would balloon the report with no signal. Decision: stay with WARN+ (existing lean).

5. **`g?` in `:Tw` buffers** opens `:TwFeedback` and prefills the form with sanitized buffer context.

   **Sanitization rule for `:Tw` buffer lines (the privacy-sensitive part):** Taskwarrior structural tokens are preserved verbatim — the user shares the *shape* of their tasks for debugging, not the *content*. Description text (free-form) has every `[A-Za-z0-9]` character replaced with `a`, preserving length and punctuation so the layout still reproduces the bug.

   Preserved verbatim:
   - Checkbox prefix: `- [ ]`, `- [x]`, `- [>]`
   - Project: `project:Work`
   - Priority: `priority:H`
   - Dates: `due:2026-04-01`, `scheduled:`, `recur:`, `wait:`, `until:`
   - Tags: `+urgent`, `-blocked`
   - Effort/depends: `effort:1h`, `depends:abc12345`
   - UUID comment: `<!-- uuid:abc12345 -->`
   - Group/header markers: `## ` prefix (the heading text itself is scrubbed)

   Scrubbed (alphanumerics → `a`):
   - Free-form description text
   - Group header content after `## `
   - Annotation text

   Example:
   ```
   - [ ] Fix login bug for user@company.com project:Work priority:H due:2026-04-01 +urgent
                                                                                          ↓
   - [ ] aaa aaaaa aaa aaa aaaa@aaaaaaa.aaa project:Work priority:H due:2026-04-01 +urgent
   ```
   Length, structural tokens, punctuation, and the email's `@`/`.` shape all preserved. Letters scrambled.

   The scrubbed buffer snapshot (max 50 lines around cursor) is shown in the form's "Anything else?" section so the user can review/redact before send.
