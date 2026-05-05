#!/usr/bin/env bash
# Render all VHS demo tapes with environment isolation and size-based sanity checks.
#
# Usage:
#   demo/render-all.sh                    # render all tapes
#   demo/render-all.sh hero burndown      # render specific tapes by name (without .tape)
#   demo/render-all.sh --validate-only    # just run validation, don't render
#
# This is the ONLY sanctioned way to regenerate demo assets. Do not run
# `vhs` directly on tape files — this wrapper enforces env isolation, validates
# tape structure, and runs post-render size checks to catch data leaks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# -- Step 0: Check dependencies -------------------------------------------

for cmd in vhs nvim task; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}ERROR${NC}: $cmd not found on PATH"
    exit 1
  fi
done

# -- Step 1: Validate all tapes -------------------------------------------

echo "=== Step 1: Validate tapes ==="
if ! bash "$SCRIPT_DIR/validate-tapes.sh"; then
  echo -e "${RED}Aborting render — tape validation failed.${NC}"
  exit 1
fi

if [ "${1:-}" = "--validate-only" ]; then
  exit 0
fi

# -- Step 2: Determine which tapes to render ------------------------------

cd "$REPO_DIR"

if [ $# -gt 0 ]; then
  tapes=()
  for name in "$@"; do
    tape="demo/sources/${name%.tape}.tape"
    if [ ! -f "$tape" ]; then
      echo -e "${RED}ERROR${NC}: $tape not found"
      exit 1
    fi
    tapes+=("$tape")
  done
else
  mapfile -t tapes < <(find demo/sources -name '*.tape' -type f | sort)
fi

echo
echo "=== Step 2: Render ${#tapes[@]} tape(s) ==="
echo

errors=0
for tape in "${tapes[@]}"; do
  name=$(basename "$tape" .tape)
  echo -n "  Rendering $name... "
  if timeout 300 vhs "$tape" >/dev/null 2>&1; then
    echo -e "${GREEN}done${NC}"
  else
    echo -e "${RED}FAILED${NC}"
    ((errors++)) || true
  fi
done

if [ "$errors" -gt 0 ]; then
  echo -e "\n${RED}$errors tape(s) failed to render.${NC}"
  exit 1
fi

# -- Step 2.5: Generate the compact launch.gif variant -------------------
#
# launch.gif is the README hero (1280×720 @ 15fps, ~4 MB). Some
# surfaces — r/neovim image preview, chat-embed thumbnails, mobile
# preview cards — want a smaller version. We re-encode from launch.mp4
# rather than re-running VHS (the mp4 is the high-fidelity source;
# this is just a downsample). Skip silently if launch.mp4 wasn't
# rendered this round.
if [ -f demo/assets/launch.mp4 ] && command -v ffmpeg &>/dev/null; then
  echo
  echo -n "  Generating launch-small.gif (960×540 @ 12fps)... "
  tmp_palette=$(mktemp --suffix=.png)
  if ffmpeg -y -loglevel error -i demo/assets/launch.mp4 \
      -vf "fps=12,scale=960:-1:flags=lanczos,palettegen=stats_mode=diff" \
      "$tmp_palette" 2>/dev/null \
      && ffmpeg -y -loglevel error -i demo/assets/launch.mp4 -i "$tmp_palette" \
      -filter_complex "fps=12,scale=960:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5" \
      demo/assets/launch-small.gif 2>/dev/null; then
    echo -e "${GREEN}done${NC}"
  else
    echo -e "${YELLOW}skip${NC} (ffmpeg failed; launch-small.gif may be stale)"
  fi
  rm -f "$tmp_palette"
fi

# -- Step 3: Post-render size checks --------------------------------------
#
# A privacy leak (rendering against a real 300+ task db instead of the 50-task
# demo seed) produces visibly larger screenshots because there's more rendered
# text. These thresholds are 3x the known-good sizes so they won't false-
# positive on minor seed changes, but will catch the "your entire real task
# database just showed up in a PNG" case.
#
# Known-good sizes (2026-04-15, 50-task seed):
#   burndown.png   ~60KB    tree.png      ~260KB    summary.png  ~68KB
#   calendar.png   ~205KB   tags.png      ~30KB
#   hero.gif       ~2.2MB   filter-group  ~638KB    quick-capture ~733KB
#   review.gif     ~572KB   delegate.gif  ~622KB    diff-preview  ~845KB

declare -A MAX_SIZES=(
  ["burndown.png"]=200
  ["tree.png"]=800
  ["summary.png"]=250
  ["calendar.png"]=700
  ["tags.png"]=150
  ["hero.gif"]=7000
  ["hero-v14.gif"]=7000
  ["filter-group.gif"]=2000
  ["quick-capture.gif"]=2500
  ["review.gif"]=2000
  ["delegate.gif"]=2000
  ["diff-preview.gif"]=3000
  # launch.gif is the README hero: 55s @ 1280×720 @ 15fps. ~4 MB
  # is fine for GitHub autoplay; ceiling at 6 MB to catch leaks.
  ["launch.gif"]=6000
  # launch-small.gif is the compact variant: 55s @ 960×540 @ 12fps,
  # ~2.7 MB. Used in size-constrained surfaces (r/neovim image
  # preview, mobile previews, chat embeds).
  ["launch-small.gif"]=4000
)

echo
echo "=== Step 3: Size-based sanity checks ==="

# nullglob: silently produce an empty list when no matching files exist,
# instead of trying to iterate over the literal pattern. Replaces the
# `2>/dev/null` that used to live on the `for` line, which is invalid
# bash (redirects don't apply to `for ... in` glob expansion).
shopt -s nullglob
size_warnings=0
for asset in demo/assets/*.png demo/assets/*.gif; do
  [ -f "$asset" ] || continue
  name=$(basename "$asset")
  size_kb=$(( $(stat -c%s "$asset" 2>/dev/null || stat -f%z "$asset" 2>/dev/null) / 1024 ))
  max="${MAX_SIZES[$name]:-0}"

  if [ "$max" -gt 0 ] && [ "$size_kb" -gt "$max" ]; then
    echo -e "  ${YELLOW}WARN${NC} $name is ${size_kb}KB (max ${max}KB) — possible data leak?"
    ((size_warnings++)) || true
  else
    echo -e "  ${GREEN}OK${NC}   $name (${size_kb}KB)"
  fi
done

echo
if [ "$size_warnings" -gt 0 ]; then
  echo -e "${YELLOW}$size_warnings size warning(s).${NC} Inspect the oversized assets manually."
  echo "If the sizes are expected (e.g. you added more seed data), update MAX_SIZES in this script."
else
  echo -e "${GREEN}All assets within expected size bounds.${NC}"
fi

echo
echo "Render complete. Assets in demo/assets/."
