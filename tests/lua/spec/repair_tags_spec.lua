-- Unit spec for the tag-repair planner (:TwRepairTags).
--
-- The planner rewrites descriptions, so its false-positive behaviour is the
-- part that matters: a description that merely *mentions* a tag in quotes
-- (a bug report, a note about a filter) must be left completely alone.

local eq = assert.are.same
local repair = require("taskwarrior.repair_tags")

describe("repair_tags.plan_for", function()
  it("moves a hyphenated tag out of the description", function()
    local p = repair.plan_for({
      uuid = "u1", description = "Taco Tuesday — grocery shop +taco-tuesday",
    })
    assert.is_truthy(p)
    eq("Taco Tuesday — grocery shop", p.new_description)
    eq({ "taco-tuesday" }, p.added_tags)
    eq({ "taco-tuesday" }, p.tags)
  end)

  it("handles several tokens anywhere in the line", function()
    local p = repair.plan_for({
      uuid = "u2", description = "+email connect michael with shon +followup",
    })
    eq("connect michael with shon", p.new_description)
    eq({ "email", "followup" }, p.added_tags)
  end)

  it("merges with tags the task already has", function()
    local p = repair.plan_for({
      uuid = "u3", description = "ship it +extra", tags = { "work" },
    })
    eq("ship it", p.new_description)
    eq({ "extra" }, p.added_tags)
    eq({ "work", "extra" }, p.tags)
  end)

  it("leaves a task alone when the tag text is already a real tag", function()
    -- Nothing is broken here: the task IS findable by +urgent. Rewriting a
    -- description purely to de-duplicate text is risk without benefit, so
    -- the planner stays out of it.
    assert.is_nil(repair.plan_for({
      uuid = "u3b", description = "ship it +urgent", tags = { "work", "urgent" },
    }))
  end)

  it("leaves a QUOTED mention alone (the bug-report case)", function()
    local p = repair.plan_for({
      uuid = "u4",
      description = 'when searching with TwFilter and "+ais-research-taste" it fails',
    })
    assert.is_nil(p, "a quoted tag mention must not be rewritten")
  end)

  it("ignores a + that is not at a word boundary", function()
    assert.is_nil(repair.plan_for({ uuid = "u5", description = "housing+food budget" }))
    assert.is_nil(repair.plan_for({ uuid = "u6", description = "sell SPY + SPYG today" }))
  end)

  it("returns nil when there is nothing to repair", function()
    assert.is_nil(repair.plan_for({
      uuid = "u7", description = "ordinary task", tags = { "work" },
    }))
  end)

  it("keeps the original description when it is nothing but tags", function()
    local p = repair.plan_for({ uuid = "u8", description = "+ais-research-taste" })
    eq({ "ais-research-taste" }, p.added_tags)
    eq("+ais-research-taste", p.new_description,
      "a tags-only description must not become empty")
  end)

  it("collapses the whitespace left behind by a removed token", function()
    local p = repair.plan_for({ uuid = "u9", description = "call +email  bob now" })
    eq("call bob now", p.new_description)
  end)
end)
