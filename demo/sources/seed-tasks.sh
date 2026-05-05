#!/usr/bin/env bash
# Seed a realistic taskwarrior db for the taskwarrior.nvim demo GIFs.
# This gets run inside the VHS container before each tape. It builds a small
# but believable set of tasks that make the plugin look useful.
set -euo pipefail

TASKRC="${TASKRC:-$HOME/.taskrc-demo}"
TASKDATA="${TASKDATA:-$HOME/.task-demo}"
rm -rf "$TASKDATA" "$TASKRC"
mkdir -p "$TASKDATA"
cat > "$TASKRC" <<EOF
data.location=$TASKDATA
confirmation=no
verbose=nothing
news.version=3.4.2
EOF
export TASKRC TASKDATA

add() {
  task rc.confirmation=no rc.verbose=nothing add "$@" >/dev/null
}

# --- work.api ---
# Most of these get an `entry:-Xd` so they were "created" days ago — the
# Burndown chart needs historical entry timestamps to draw a curve.
add "Review pull request 1284 for auth refactor" project:work.api priority:H due:tomorrow +review entry:-21d
add "Investigate tail latency spike in /search" project:work.api priority:H +bug +p1 entry:-14d
add "Document new rate limiter thresholds" project:work.api priority:L entry:-10d +review
add "Migrate session store to Redis 7" project:work.api priority:M due:friday entry:-7d
add "Add structured logging to /api/checkout" project:work.api priority:M entry:-4d +review

# --- work.infra ---
add "Rotate staging certificates before expiry" project:work.infra priority:H due:tomorrow +blocker entry:-18d
add "Upgrade CI runners to Ubuntu 24.04" project:work.infra priority:M entry:-12d
add "Audit IAM policies for prod buckets" project:work.infra priority:M +security entry:-9d
add "Trace flaky deploy hook on main" project:work.infra priority:M +bug entry:-3d

# --- writing ---
add "Draft launch blog post for taskwarrior.nvim" project:writing priority:M due:monday +review entry:-14d
add "Outline talk: editing taskwarrior like oil.nvim" project:writing priority:L entry:-7d

# --- personal ---
add "Book flight for April conference" project:personal priority:H due:friday entry:-25d
add "Pay April electricity bill" project:personal due:2026-04-15 entry:-30d
add "Call mom about weekend plans" project:personal entry:-2d

# --- COMPLETED tasks (give Burndown a curve to draw) ---
# These are added as `add` then immediately `done`. With backdated
# entry+end, the burndown shows tasks burning down over time.
done_back() {
  local desc="$1"; shift
  task rc.confirmation=no rc.verbose=nothing add "$@" "$desc" >/dev/null
  local uuid
  uuid=$(task rc.confirmation=no rc.verbose=nothing description:"$desc" export \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["uuid"])')
  task rc.confirmation=no rc.verbose=nothing "$uuid" done >/dev/null
}
done_back "Set up demo seed script"          project:writing entry:-30d
done_back "Wire up auth middleware"           project:work.api priority:H entry:-25d
done_back "Bump Postgres to 16"               project:work.infra entry:-22d
done_back "Send Q1 retro notes"               project:work.api entry:-18d
done_back "File expense report — March"       project:personal entry:-15d
done_back "Pair on payment-api refactor"      project:work.api priority:M entry:-11d
done_back "Update README install snippet"     project:writing entry:-9d
done_back "Investigate slow s3 sync job"      project:work.infra +bug entry:-6d
done_back "Run quarterly disk-space cleanup"  project:work.infra entry:-3d

# Start one so we get a [>] marker in the demo
WIP_UUID=$(task rc.confirmation=no rc.verbose=nothing project:work.api \
  description:"Investigate tail latency spike in /search" export \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["uuid"])')
task rc.confirmation=no rc.verbose=nothing "$WIP_UUID" start >/dev/null
