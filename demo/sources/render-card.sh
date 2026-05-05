#!/usr/bin/env bash
# Animated full-screen brand card for the launch demo.
# Used as BOTH the intro card AND the end card — same animation,
# different hold duration.
#
# Usage:
#   bash render-card.sh <hold_seconds>
#
# Layout philosophy:
#   • Designed to fill a ~96×24 terminal (1280×720 / FontSize 18).
#   • Title-bar gradient is a 2-row band that dominates the top third.
#   • Commands box is wide (~80 cols) so it reads as a confident
#     poster, not a small notice.
#   • Horizontally + vertically centered with padding computed from
#     `tput cols` / `tput lines` so the layout adapts if VHS settings
#     change.
#   • Animation is a ~2.5s reveal: 2-row gradient sweeps in column-
#     by-column, title appears, subtitle drops, commands box draws,
#     footer slides in. Resets terminal first so no shell prompt or
#     `bash` command line leaks.
#
# Palette: Catppuccin Mocha (matches the demo terminal theme).

set -euo pipefail

HOLD="${1:-10}"

# ── Terminal dimensions ─────────────────────────────────────────────────────
COLS=$(tput cols 2>/dev/null || echo 96)
ROWS=$(tput lines 2>/dev/null || echo 24)

pad()  { printf "%*s" "$1" ""; }
nl_n() { for _ in $(seq 1 "$1"); do printf '\n'; done; }

# ── ANSI helpers ────────────────────────────────────────────────────────────
# Use $'...' (ANSI-C quoting) so the variables hold REAL escape bytes,
# not the 6-char literal "\033[0m". Otherwise printf "%s" would print
# the literal text instead of applying the attribute.
fg() { printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"; }
B=$'\033[1m'
D=$'\033[2m'
I=$'\033[3m'
R=$'\033[0m'

PINK=$(fg 245 194 231)
MAUVE=$(fg 203 166 247)
SKY=$(fg 137 220 235)
TEAL=$(fg 148 226 213)
GREEN=$(fg 166 227 161)
YELLOW=$(fg 249 226 175)
PEACH=$(fg 250 179 135)
TEXT=$(fg 205 214 244)
SUBTEXT=$(fg 166 173 200)
OVERLAY=$(fg 127 132 156)

# 7-stop pink → mauve → blue gradient
G1=$(fg 245 194 231); G2=$(fg 234 180 239); G3=$(fg 222 173 245)
G4=$(fg 203 166 247); G5=$(fg 168 175 248); G6=$(fg 137 180 250)
G7=$(fg 116 199 236)
GRADIENT=("$G1" "$G2" "$G3" "$G4" "$G5" "$G6" "$G7")

# ── Layout dimensions ──────────────────────────────────────────────────────
# Each gradient bar: 9 chars wide. 7 bars + 6 single-space separators
# = 7*9 + 6 = 69 chars. Box width matches.
BAR_W=9
BARS=7
GAP=1  # single-space between bars
TITLE_BAR_W=$(( BARS * BAR_W + (BARS - 1) * GAP ))   # 7*9 + 6 = 69
CONTENT_W=$TITLE_BAR_W

LPAD=$(( (COLS - CONTENT_W) / 2 ))
if [ "$LPAD" -lt 0 ]; then LPAD=0; fi

# Content rows: gradient (2) + blank (1) + title (1) + blank (1) +
# subtitle (2) + blank (1) + commands box (8) + blank (1) + URL (1) +
# blank (1) + footer (1) = 20 rows.
CONTENT_H=20
TOP_PAD=$(( (ROWS - CONTENT_H) / 2 ))
if [ "$TOP_PAD" -lt 1 ]; then TOP_PAD=1; fi

# ── Reset terminal, hide cursor ─────────────────────────────────────────────
printf '\033c'
printf '\033[?25l'
sleep 0.4

# ── Vertical centering pad ──────────────────────────────────────────────────
nl_n "$TOP_PAD"

# ── Step 1: 2-row gradient bars sweep in column-by-column ───────────────────
# Print row 1 with delays, then row 2 (instant — completes the wipe).
pad "$LPAD"
for c in "${GRADIENT[@]}"; do
  printf "${c}${B}█████████${R} "
  sleep 0.06
done
printf '\n'

pad "$LPAD"
for c in "${GRADIENT[@]}"; do
  printf "${c}${B}█████████${R} "
done
printf '\n'
sleep 0.18

# ── Step 2: title (centered under the bars) ─────────────────────────────────
printf '\n'
TITLE="taskwarrior.nvim"
TITLE_PAD=$(( LPAD + (CONTENT_W - ${#TITLE}) / 2 ))
pad "$TITLE_PAD"
printf "${MAUVE}${B}${TITLE}${R}\n"
sleep 0.20

printf '\n'

# ── Step 3: subtitle ────────────────────────────────────────────────────────
SUB1="Edit your Taskwarrior tasks as markdown."
SUB2="Every vim motion becomes a task management operation."
pad $(( LPAD + (CONTENT_W - ${#SUB1}) / 2 ))
printf "${TEXT}${SUB1}${R}\n"
sleep 0.18
pad $(( LPAD + (CONTENT_W - ${#SUB2}) / 2 ))
printf "${SUBTEXT}${SUB2}${R}\n"
sleep 0.30

printf '\n'

# ── Step 4: commands box ────────────────────────────────────────────────────
# Box border total width = CONTENT_W. Inner area = CONTENT_W - 4
# (├─2 chars─, ─2 chars─┤). Each row is "│  KEY <gap> DESC <pad> │"
# with key field = 12 chars and trailing fill so total = CONTENT_W.
# Pre-computed border strings below.
BOX_TOP="${OVERLAY}╭─ ${MAUVE}commands${R} ${OVERLAY}─────────────────────────────────────────────────────╮${R}"
BOX_BOT="${OVERLAY}╰─────────────────────────────────────────────────────────────────────╯${R}"

# Inner row template — visible width (without ANSI) is exactly CONTENT_W.
# "│  KEY12       DESC<padded>   │" → 1 + 2 + 12 + 4 + 47 + 3 + 1 = 70 chars wait that's off.
# Let me count: "│" + 2 spaces + 12-char key + 5 spaces + 46-char desc + 3 spaces + "│"
#               = 1 + 2 + 12 + 5 + 46 + 3 + 1 = 70 → still need 69. Trim by 1 trailing space.

cmd_row() {
  local key="$1" desc="$2"
  # Pad key field to 12 chars, desc field to 49 chars (visible widths)
  local key_padded
  printf -v key_padded "%-12s" "$key"
  local desc_padded
  printf -v desc_padded "%-49s" "$desc"
  pad "$LPAD"
  printf "${OVERLAY}│${R}  ${YELLOW}${B}%s${R}  ${TEXT}%s${R} ${OVERLAY}│${R}\n" "$key_padded" "$desc_padded"
}

pad "$LPAD"; printf "%s\n" "$BOX_TOP"
sleep 0.10
cmd_row ":Tw"        "view pending tasks"
sleep 0.10
cmd_row "<leader>ta" "quick capture from any buffer"
sleep 0.10
cmd_row ":TwTree"    "dependency graph"
sleep 0.10
cmd_row ":TwReview"  "urgency-ordered triage walk"
sleep 0.10
cmd_row ":TwTutor"   "interactive 20-min tutorial"
sleep 0.10
pad "$LPAD"; printf "%s\n" "$BOX_BOT"
sleep 0.20

printf '\n'

# ── Step 5: URL + footer ────────────────────────────────────────────────────
URL_LINE="★  github.com/MattHandzel/taskwarrior.nvim"
pad $(( LPAD + (CONTENT_W - ${#URL_LINE}) / 2 ))
printf "${PEACH}★${R}  ${SKY}${B}github.com/MattHandzel/taskwarrior.nvim${R}\n"
sleep 0.20

printf '\n'

FOOTER="MIT  ·  feedback welcome on r/neovim"
pad $(( LPAD + (CONTENT_W - ${#FOOTER}) / 2 ))
printf "${GREEN}MIT${R}  ${OVERLAY}·${R}  ${TEAL}${I}feedback welcome on r/neovim${R}\n"

# ── Hold ────────────────────────────────────────────────────────────────────
HOLD_AFTER=$(awk "BEGIN { v = $HOLD - 2.5; if (v < 0.5) v = 0.5; print v }")
sleep "$HOLD_AFTER"
sleep 0.6

printf '\033[?25h'
