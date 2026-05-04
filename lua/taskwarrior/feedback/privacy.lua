-- lua/taskwarrior/feedback/privacy.lua
--
-- Privacy primitives for the easy-feedback flow. Two functions:
--
--   bucket_count(n)        differential-privacy-style bucket for numeric
--                          counters. Returns a string range ("11-25",
--                          "26-100", …) instead of the raw integer to
--                          prevent unique-identification.
--
--   scrub_task_line(line)  preserves Taskwarrior structural tokens
--                          (project:, +tags, due:, …) verbatim while
--                          scrambling free-form description text by
--                          replacing alphanumerics with `a`. Length and
--                          punctuation are preserved so layout-sensitive
--                          bug reports stay reproducible.
--
-- See docs/launch/feedback-flow-design.md for the design context.

local M = {}

-- ─────────────────────────────────────────────────────────────────────────
-- bucket_count — DP-style bucketing for numeric counters
-- ─────────────────────────────────────────────────────────────────────────
--
-- Buckets are roughly logarithmic so each is wide enough that membership
-- is not unique-identifying. The user gets a sense of scale ("you have
-- about 100 tasks"); the report doesn't doxx them via an exact figure
-- that, combined with timestamps and OS, narrows them to a single user.

-- Bucket boundaries: the upper bound (inclusive) of each bucket. The
-- final bucket has no upper bound and is reported as "<lower>+".
-- Order matters — must be ascending. `_bucket_index` returns the index
-- (1-based) of the bucket containing n, exposed for monotonicity tests.
local BUCKETS = {
  { upper = 0,     label = "0" },
  { upper = 2,     label = "1-2" },
  { upper = 5,     label = "3-5" },
  { upper = 10,    label = "6-10" },
  { upper = 25,    label = "11-25" },
  { upper = 100,   label = "26-100" },
  { upper = 500,   label = "101-500" },
  { upper = 2000,  label = "501-2000" },
  { upper = 10000, label = "2001-10000" },
  { upper = nil,   label = "10001+" },  -- catch-all
}

function M._bucket_index(n)
  if type(n) ~= "number" or n ~= n then return 1 end  -- nil/NaN → "0" bucket
  if n < 0 then return 1 end
  for i, b in ipairs(BUCKETS) do
    if b.upper == nil or n <= b.upper then return i end
  end
  return #BUCKETS  -- unreachable; catch-all has nil upper
end

function M.bucket_count(n)
  return BUCKETS[M._bucket_index(n)].label
end

-- ─────────────────────────────────────────────────────────────────────────
-- scrub_task_line — preserve structural tokens, scrub description content
-- ─────────────────────────────────────────────────────────────────────────
--
-- Algorithm: walk the line character-by-character, but at each position
-- check whether the substring starting there matches one of the known
-- structural patterns. If yes, copy the matched substring verbatim and
-- advance past it. Otherwise, copy one character — replacing alphanumeric
-- with `a` — and advance one position.
--
-- Length is preserved character-for-character, which matters for the
-- `g?` shortcut: a layout bug at column 80 needs to reproduce at
-- column 80 in the report.

-- Patterns in priority order. Each is a Lua pattern anchored at the
-- start of the substring being checked. If matched, the entire matched
-- substring is preserved verbatim. List order matters for ambiguity:
-- longer / more-specific patterns must come first.
--
-- The leading `^` is implicit (we apply via string.match against a
-- substring starting at the current cursor position).
local STRUCTURAL_PATTERNS = {
  -- Checkbox prefix at line start: `- [ ]`, `- [x]`, `- [>]`, `- [!]`
  -- (anchored at column 1 only — the caller handles that).
  -- This one is handled separately because it only matches at line start.

  -- UUID comment — must come early so it's not mis-parsed as words+colon.
  "^<!%-%- uuid:[%w%-]+ %-%->",
  -- Taskwarrior date/time fields. The value can be an ISO date,
  -- duration, "tomorrow", "eow", "2026-04-01T10:00", etc.
  "^due:[%w%-:T+]+",
  "^scheduled:[%w%-:T+]+",
  "^until:[%w%-:T+]+",
  "^wait:[%w%-:T+]+",
  "^recur:[%w%-:T+]+",
  -- Project: a dotted/hyphenated identifier.
  "^project:[%w._%-]+",
  -- Priority: H, M, or L.
  "^priority:[HMLhml]",
  -- Effort: numeric + unit (1h30m, 45m, 2.5h, ISO duration PT1H30M).
  "^effort:[%w.:+]+",
  -- Depends: comma-separated list of UUIDs/IDs.
  "^depends:[%w,%-]+",
  -- Tags: `+name`, `-name`, with hyphens allowed in the name.
  "^[+%-][%w][%w%-]*",
}

local function scrub_char(c)
  if c:match("[%w]") then return "a" end
  return c
end

function M.scrub_task_line(line)
  if not line or line == "" then return line or "" end

  -- Step 1 — detect a leading checkbox prefix and preserve verbatim.
  -- Pattern: optional indent, "-", space, "[", state char, "]". The state
  -- char is one of: space (pending), x (done), > (started), ! (urgent),
  -- - (blocked). The trailing space (if any) is left for the main loop
  -- to pass through as whitespace, so this matches both "- [x]" (bare
  -- checkbox, no description) and "- [x] task" alike.
  local prefix, rest_start = line:match("^(%s*%- %[[%sx>!%-]%])()")
  local out = {}
  local i
  if prefix then
    table.insert(out, prefix)
    i = rest_start
  elseif line:match("^#+%s") then
    -- Step 2 — markdown header (group label). Preserve `## ` prefix,
    -- scrub the rest by the description rule.
    local hashes = line:match("^(#+%s)")
    table.insert(out, hashes)
    i = #hashes + 1
  else
    -- No structural prefix; whole line is description-like.
    i = 1
  end

  -- Step 3 — walk the rest of the line. At each position, try every
  -- structural pattern; if one matches, preserve verbatim and skip.
  -- Otherwise, scrub one character and advance.
  while i <= #line do
    local matched = nil
    local sub = line:sub(i)
    for _, pat in ipairs(STRUCTURAL_PATTERNS) do
      local m = sub:match(pat)
      if m then
        matched = m
        break
      end
    end

    if matched then
      table.insert(out, matched)
      i = i + #matched
    else
      table.insert(out, scrub_char(line:sub(i, i)))
      i = i + 1
    end
  end

  return table.concat(out)
end

return M
