# GIF purpose: The single wow-moment asset — "every vim motion is a task op."
#   This is the v1.4 hero. Drops the existing hero's substitute-bulk-edit
#   beat (which is dense at small playback sizes) for a sequence that reads
#   in 12s on mute, mobile-first: Open → toggle done → add inline → bulk-delete
#   → save → re-render. A hidden external `task add` between the bulk-delete
#   and the save makes the new task appear in the re-rendered buffer
#   alongside the user's edits, demonstrating conflict-aware save without
#   needing a caption (alert viewers will notice; cold viewers see only a
#   tight, oil.nvim-style demo).
#
# Story beat: open :Task → <CR> toggles done → o adds → V-d bulk-deletes →
#             [hidden: external `task add`] → :w → re-render shows external
#             task survived alongside the local edits
# Target platform: README hero, r/neovim/r/taskwarrior/HN top-of-post
# Length target: ~14s

Output demo/assets/hero-v14.gif

Require nvim
Require task

Set Shell "bash"
Set Theme "Catppuccin Mocha"
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 18
Set Width 1280
Set Height 720
Set Padding 40
Set TypingSpeed 70ms
Set PlaybackSpeed 1.0

Env TASKRC "/tmp/task-nvim-demo/.taskrc-demo"
Env TASKDATA "/tmp/task-nvim-demo/.task-demo"

# Seed the demo db AND launch nvim — hidden so the GIF starts directly on
# the rendered task buffer (no boilerplate typing).
Hide
Type "mkdir -p /tmp/task-nvim-demo && export TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo && bash demo/sources/seed-tasks.sh && clear"
Enter
Sleep 500ms
Type "TASKRC=/tmp/task-nvim-demo/.taskrc-demo TASKDATA=/tmp/task-nvim-demo/.task-demo nvim -u demo/sources/demo-init.lua"
Enter
Sleep 3s
Show

# 0-2s: reader pause on the rendered buffer
Sleep 2s

# 2-4s: cursor down to a task, <CR> toggles it done — a single vim motion
# changes Taskwarrior state (after the upcoming :w)
Type "3j"
Sleep 500ms
Enter
Sleep 1500ms

# 4-7s: `o` adds a new task line inline with full Taskwarrior metadata syntax
Type "o"
Sleep 200ms
Type "Buy milk +groceries due:fri"
Sleep 1200ms
Escape
Sleep 600ms

# 7-9s: visual-select two lines and `d` — bulk-delete is a vim motion
Type "G"
Sleep 300ms
Type "Vk"
Sleep 600ms
Type "d"
Sleep 1500ms

# 9-10s: HIDDEN — external `task add` simulates a concurrent writer
# (mobile sync, another shell, a hook). The buffer still shows the local
# edits; the next render will pick this up alongside them.
Hide
Type ":!task rc.confirmation=no rc.verbose=nothing add 'External: capture from phone' project:personal +sync"
Enter
Sleep 800ms
Show

# 10-14s: :w applies the local edits AND re-renders. The "External: capture
# from phone" line appears at the top of personal — it survived the save
# rather than being clobbered by the diff. (Only sharp-eyed viewers notice;
# the README and HN post body do the heavy lifting of explaining why.)
Type ":w"
Sleep 500ms
Enter
Sleep 3500ms
