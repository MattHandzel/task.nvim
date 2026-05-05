# Asset: demo/assets/launch.mp4
# Purpose: ~65s combined launch video for r/neovim, HN, X.
#
# Story arc:
#   intro card (~4s, animated)
#     → Hero — vim motions on tasks
#     → Quick-capture from any buffer
#     → Filter + group  (combines naturally — both modify the rendered view)
#     → Five-views sweep — fullscreen Tree, Burndown, Calendar, Tags
#     → Guided review walk
#     → Live diff preview
#     → End card (10s, same animation)
#
# Pacing:
#   • Typing speed bumped 60→80ms so commands are easy to read.
#   • Per-scene Sleep increased so the viewer has time to ABSORB what
#     happened before the next scene starts. Earlier iterations of this
#     tape ran each scene in ~3s and viewers couldn't tell what changed.
#   • Visualizations open as fullscreen tabs (v1.5+) so each gets the
#     entire frame for ~3s before we move on.
#
# Length target: ~62–68s. Reddit autoplay caps interest around 60–75s.

Output demo/assets/launch.mp4
# Also emit a GIF for the README hero — GIFs autoplay in GitHub
# previews where MP4 needs an explicit play tap.
Output demo/assets/launch.gif

Require nvim
Require task

Set Shell "bash"
Set Theme "Catppuccin Mocha"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 18
Set Width 1280
Set Height 720
Set Padding 0
Set TypingSpeed 80ms
Set PlaybackSpeed 1.0

Env TASKRC "/tmp/task-nvim-demo/.taskrc-demo"
Env TASKDATA "/tmp/task-nvim-demo/.task-demo"

# === Hidden setup ============================================================
Hide
Type "mkdir -p /tmp/task-nvim-demo && export TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo && bash demo/sources/seed-tasks.sh && clear"
Enter
Sleep 600ms

# === Intro card (~4s, animated) =============================================
Type "bash demo/sources/render-card.sh 4"
Enter
Sleep 100ms
Show
Sleep 4000ms
Hide

# === Cut: launch nvim =======================================================
Type "clear"
Enter
Sleep 200ms
Type "TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo nvim -u demo/sources/demo-init.lua"
Enter
Sleep 2500ms
Show

# === Scene 1: Hero — bulk-edit with vim motions =============================
# 2.5s for viewer to scan the seeded task list before the substitute fires.
Sleep 2500ms
Type ":%s/priority:L/priority:H/g"
Enter
# Confirm prompt visible — give 2s to read which tasks will change.
Sleep 2500ms
Type ":w"
Enter
# 3s after save so the "Applied: N modified" notify is readable.
Sleep 3000ms

# === Scene 2: Quick-capture from any buffer =================================
Type " ta"
Sleep 1500ms
Type "Ship launch video project:writing priority:H due:today"
Sleep 1500ms
Enter
# 2.5s for viewer to see the new task land in the buffer.
Sleep 2500ms

# === Scene 3: Filter + group ================================================
# Filter narrows to 7 work.* tasks; group splits them into two ## headers.
# Pre-v1.5 this used `+work` which matched zero tasks — black screen bug.
Type ":TwFilter project.startswith:work"
Enter
Sleep 2200ms
Type ":TwGroup project"
Enter
Sleep 3000ms
# Reset both before the next scene so the view is clean.
Type ":TwFilter "
Enter
Sleep 800ms
Type ":TwGroup none"
Enter
Sleep 800ms

# === Scene 4: Dependency tree (fullscreen tab) ==============================
Type ":TwTree"
Enter
Sleep 3500ms
Type ":tabclose"
Enter
Sleep 600ms

# === Scene 5: Burndown (fullscreen tab) =====================================
Type ":TwBurndown"
Enter
Sleep 3500ms
Type ":tabclose"
Enter
Sleep 600ms

# === Scene 6: Calendar (fullscreen tab) =====================================
Type ":TwCalendar"
Enter
Sleep 3500ms
Type ":tabclose"
Enter
Sleep 600ms

# === Scene 7: Tags (fullscreen tab) =========================================
Type ":TwTags"
Enter
Sleep 3500ms
Type ":tabclose"
Enter
Sleep 600ms

# === Scene 8: Guided review =================================================
# Three keystrokes (k = keep, d = defer, q = quit) with 1.5s between
# so the viewer can see the review form react.
Type ":TwReview"
Enter
Sleep 2500ms
Type "k"
Sleep 1700ms
Type "d"
Sleep 1700ms
Type "q"
Sleep 800ms

# === Scene 9: Live diff preview =============================================
Type ":TwDiffPreview on"
Enter
Sleep 1200ms
Type ":1"
Enter
Type "A +urgent"
Escape
Sleep 2200ms
Type ":w"
Enter
Sleep 2800ms

# === End card (10s, same animation as intro) ================================
Type ":qa!"
Enter
Sleep 200ms
Hide
Type "bash demo/sources/render-card.sh 10"
Enter
Sleep 100ms
Show
Sleep 10000ms
