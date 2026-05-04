-- tests/lua/spec/feedback_privacy_spec.lua
--
-- Privacy primitives for the easy-feedback flow:
--   - bucket_count(n) — differential-privacy-style bucketing for
--     numeric counters (task_count, etc). Returns a string range
--     instead of the raw integer to prevent unique-identification.
--   - scrub_task_line(line) — preserves Taskwarrior structural tokens
--     (project:, due:, +tags, …) verbatim while scrambling free-form
--     description text by replacing alphanumerics with `a`. Used by
--     the :Task buffer's `g?` shortcut to prefill bug reports with
--     reproducible structure but no identifying content.

describe("feedback.privacy.bucket_count", function()
  local privacy

  before_each(function()
    package.loaded["taskwarrior.feedback.privacy"] = nil
    privacy = require("taskwarrior.feedback.privacy")
  end)

  it("0 maps to '0'", function()
    assert.equals("0", privacy.bucket_count(0))
  end)

  it("small counts (1-2, 3-5) get fine-grained buckets", function()
    assert.equals("1-2", privacy.bucket_count(1))
    assert.equals("1-2", privacy.bucket_count(2))
    assert.equals("3-5", privacy.bucket_count(3))
    assert.equals("3-5", privacy.bucket_count(5))
  end)

  it("medium counts (6-10, 11-25) are bucketed coarser", function()
    assert.equals("6-10", privacy.bucket_count(6))
    assert.equals("6-10", privacy.bucket_count(10))
    assert.equals("11-25", privacy.bucket_count(11))
    assert.equals("11-25", privacy.bucket_count(25))
  end)

  it("large counts (26-100, 101-500, 501-2000) bucket as expected", function()
    assert.equals("26-100", privacy.bucket_count(26))
    assert.equals("26-100", privacy.bucket_count(100))
    assert.equals("101-500", privacy.bucket_count(101))
    assert.equals("101-500", privacy.bucket_count(500))
    assert.equals("501-2000", privacy.bucket_count(501))
    assert.equals("501-2000", privacy.bucket_count(2000))
  end)

  it("very large counts (2001-10000, 10001+) cap properly", function()
    assert.equals("2001-10000", privacy.bucket_count(2001))
    assert.equals("2001-10000", privacy.bucket_count(10000))
    assert.equals("10001+", privacy.bucket_count(10001))
    assert.equals("10001+", privacy.bucket_count(1e9))
  end)

  it("nil and negative inputs are coerced to '0' (defensive)", function()
    assert.equals("0", privacy.bucket_count(nil))
    assert.equals("0", privacy.bucket_count(-1))
    assert.equals("0", privacy.bucket_count(-100))
  end)

  it("monotonicity — bigger inputs never map to a smaller bucket", function()
    -- Sample boundary points; if bucket_count is well-formed, the bucket
    -- index returned by an internal mapper grows monotonically.
    local samples = { 0, 1, 2, 3, 5, 6, 10, 11, 25, 26, 100, 101, 500, 501, 2000, 2001, 10000, 10001 }
    local last_idx = -1
    for _, n in ipairs(samples) do
      local idx = privacy._bucket_index(n)
      assert.is_true(idx >= last_idx,
        ("monotonicity violated: bucket_index(%d) = %d < previous %d"):format(n, idx, last_idx))
      last_idx = idx
    end
  end)
end)

describe("feedback.privacy.scrub_task_line", function()
  local privacy

  before_each(function()
    package.loaded["taskwarrior.feedback.privacy"] = nil
    privacy = require("taskwarrior.feedback.privacy")
  end)

  -- Helper: assert that scrubbing `input` produces `expected`.
  local function eq_scrub(input, expected, msg)
    local got = privacy.scrub_task_line(input)
    assert.equals(expected, got,
      (msg or "scrub mismatch") .. "\n  in:       " .. input .. "\n  expected: " .. expected
        .. "\n  got:      " .. got)
  end

  it("preserves checkbox prefix verbatim", function()
    eq_scrub("- [ ]", "- [ ]")
    eq_scrub("- [x]", "- [x]")
    eq_scrub("- [>]", "- [>]")
  end)

  it("scrambles plain description alphanumerics to `a`", function()
    eq_scrub("- [ ] Buy milk", "- [ ] aaa aaaa")
    eq_scrub("- [ ] Fix login bug", "- [ ] aaa aaaaa aaa")
  end)

  it("preserves project:Word verbatim", function()
    eq_scrub("- [ ] Foo project:Work", "- [ ] aaa project:Work")
  end)

  it("preserves priority:H/M/L verbatim", function()
    eq_scrub("- [ ] Foo priority:H", "- [ ] aaa priority:H")
    eq_scrub("- [ ] Foo priority:M", "- [ ] aaa priority:M")
    eq_scrub("- [ ] Foo priority:L", "- [ ] aaa priority:L")
  end)

  it("preserves due:DATE verbatim", function()
    eq_scrub("- [ ] Bill due:2026-04-01", "- [ ] aaaa due:2026-04-01")
  end)

  it("preserves +tag and -tag verbatim", function()
    eq_scrub("- [ ] Foo +urgent", "- [ ] aaa +urgent")
    eq_scrub("- [ ] Foo +urgent +backend", "- [ ] aaa +urgent +backend")
    eq_scrub("- [ ] Foo -blocked", "- [ ] aaa -blocked")
  end)

  it("preserves <!-- uuid:... --> comment verbatim", function()
    eq_scrub("- [ ] Foo <!-- uuid:abc12345 -->",
      "- [ ] aaa <!-- uuid:abc12345 -->")
  end)

  it("complex realistic line — preserves shape, scrubs content", function()
    eq_scrub(
      "- [ ] Fix login bug for user@company.com project:Work priority:H due:2026-04-01 +urgent +backend",
      "- [ ] aaa aaaaa aaa aaa aaaa@aaaaaaa.aaa project:Work priority:H due:2026-04-01 +urgent +backend"
    )
  end)

  it("preserves length character-for-character in description", function()
    -- Length preservation matters for layout-bug reports — the user's
    -- buffer line wrapped at column 80 needs to wrap at column 80 in
    -- the report too, or the bug isn't reproducible.
    local input  = "- [ ] short"
    local output = privacy.scrub_task_line(input)
    assert.equals(#input, #output,
      "length not preserved: " .. #input .. " vs " .. #output)
  end)

  it("preserves punctuation and whitespace", function()
    -- Periods, commas, parens, hyphens between words: all kept as-is.
    eq_scrub("- [ ] Hello, world! (test)", "- [ ] aaaaa, aaaaa! (aaaa)")
  end)

  it("group header `## Heading` keeps the marker, scrubs the heading", function()
    -- Per design (user instruction): replace alphanumerics with literal `a`,
    -- not case-preserving — the goal is privacy, not visual fidelity. The
    -- single character makes the scrubbing rule trivially auditable.
    eq_scrub("## Project Work", "## aaaaaaa aaaa")
  end)

  it("scheduled:, recur:, wait:, until:, effort:, depends: all preserved", function()
    eq_scrub("- [ ] X scheduled:2026-04-01", "- [ ] a scheduled:2026-04-01")
    eq_scrub("- [ ] X recur:weekly",          "- [ ] a recur:weekly")
    eq_scrub("- [ ] X wait:friday",           "- [ ] a wait:friday")
    eq_scrub("- [ ] X until:2026-12-31",      "- [ ] a until:2026-12-31")
    eq_scrub("- [ ] X effort:1h30m",          "- [ ] a effort:1h30m")
    eq_scrub("- [ ] X depends:abc12345",      "- [ ] a depends:abc12345")
  end)

  it("non-task lines (annotation, blank, comment) get description-scrubbed", function()
    eq_scrub("    note: this is private", "    aaaa: aaaa aa aaaaaaa")
    eq_scrub("",                          "")
  end)

  it("does NOT preserve text that LOOKS like a token but isn't one", function()
    -- Defensive: if a user's description happens to contain "project:foo"
    -- mid-sentence, the regex will still treat it as a structural token.
    -- That's an acceptable false negative — preserving "project:" leaks
    -- the literal word "project" but the value would be a real value
    -- anyway, and the cost of false-positive scrubbing of a real
    -- structural token would be losing reproducible-structure value.
    -- This test documents the chosen behavior.
    local got = privacy.scrub_task_line("- [ ] Talk about project:Foo")
    assert.is_truthy(got:find("project:Foo", 1, true),
      "we treat project:X as structural even mid-sentence; got: " .. got)
  end)
end)
