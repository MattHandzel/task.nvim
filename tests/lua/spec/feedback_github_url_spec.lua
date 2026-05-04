-- tests/lua/spec/feedback_github_url_spec.lua
--
-- "Open as GitHub issue" path. Two failure modes the user just hit:
--
--   1. URL too long — body URL-encoded into the issue prefill URL
--      blows past GitHub's ~8KB limit; user lands on
--      "Whoa there! Your request URL is too long."
--
--   2. Stale task_count field — was renamed to task_count_bucket in
--      the payload but the GitHub URL builder still references the
--      old name, producing "task_count: nil" in every report.
--
-- Both surfaced because the spec previously only tested
-- the payload BUILDER, never the URL path that consumes it. Lesson
-- repeats: assertions on intermediate state aren't a substitute for
-- assertions on the user-visible surface.

local function reset()
  for k in pairs(package.loaded) do
    if k:match("^taskwarrior") then package.loaded[k] = nil end
  end
end

describe("feedback GitHub URL — length-aware prefill", function()
  local feedback
  local opened_url, clipboard

  before_each(function()
    reset()
    require("taskwarrior").setup({})
    feedback = require("taskwarrior.feedback")

    -- Capture vim.ui.open / xdg-open so the test sees what URL would
    -- have been opened.
    opened_url = nil
    vim.ui.open = function(url) opened_url = url end

    -- Capture clipboard writes via vim.fn.setreg.
    clipboard = nil
    local orig_setreg = vim.fn.setreg
    rawset(vim.fn, "setreg", function(reg, val)
      if reg == "+" then clipboard = tostring(val) end
      return orig_setreg(reg, val)
    end)
  end)

  it("small body → URL-encoded into the prefill URL (no clipboard fallback)", function()
    local payload = {
      client = {
        plugin_version    = "v1.4.1",
        nvim_version      = "0.10.0",
        os                = "Linux/x86_64",
        tw_version        = "3.4.2",
        backend           = "lua",
        task_count_bucket = "26-100",
        config_summary    = {},
      },
      report = {
        what_happened = "small report",
        expected      = "expected to work",
        other         = "no extra notes",
      },
      submitted_at = "2026-05-04T12:00:00Z",
    }
    feedback._open_github_issue(payload, "MattHandzel/taskwarrior.nvim")
    assert.is_string(opened_url, "no URL was opened")
    -- Body is in the URL.
    assert.is_truthy(opened_url:find("body=", 1, true), "URL missing body= param")
    assert.is_truthy(opened_url:find("small%%20report")
                  or opened_url:find("small+report"),
      "URL body does not contain the report content")
    -- No clipboard fallback for small payloads.
    assert.is_nil(clipboard, "clipboard should not be touched for small payloads")
  end)

  it("oversized body → body copied to clipboard, URL opens with placeholder", function()
    -- Build a payload whose body would exceed GitHub's URL limit.
    -- 25 long task lines, each ~400 chars after url_encode → ~10KB body.
    local big_lines = {}
    for i = 1, 30 do
      table.insert(big_lines, string.rep("a", 400) .. " line " .. i)
    end
    local big_other = table.concat(big_lines, "\n")

    local payload = {
      client = {
        plugin_version = "v1.4.1", nvim_version = "0.10.0",
        os = "Linux", tw_version = "3.4.2", backend = "lua",
        task_count_bucket = "26-100", config_summary = {},
      },
      report = {
        what_happened = "buffer rendering broke",
        expected      = "should render",
        other         = big_other,
      },
      submitted_at = "2026-05-04T12:00:00Z",
    }
    feedback._open_github_issue(payload, "MattHandzel/taskwarrior.nvim")

    assert.is_string(opened_url, "no URL was opened")
    -- The full body must NOT be in the URL.
    assert.is_nil(opened_url:find(string.rep("a", 200), 1, true),
      "oversized body leaked into URL — fallback didn't trigger")
    -- The opened URL must mention the clipboard (placeholder).
    assert.is_truthy(opened_url:lower():find("clipboard")
                  or opened_url:lower():find("paste"),
      "fallback URL should tell the user where to paste from; got: "
        .. opened_url)
    -- The full body must be on the clipboard.
    assert.is_string(clipboard, "clipboard not set on fallback")
    assert.is_truthy(clipboard:find("buffer rendering broke", 1, true),
      "clipboard missing 'what happened' content")
    assert.is_truthy(clipboard:find(string.rep("a", 200), 1, true),
      "clipboard missing the long body content")
    -- And the URL must be under the limit.
    assert.is_true(#opened_url < 8000,
      "fallback URL itself is too long: " .. #opened_url .. " chars")
  end)
end)

describe("feedback GitHub URL — env block field consistency", function()
  local feedback

  before_each(function()
    reset()
    require("taskwarrior").setup({})
    feedback = require("taskwarrior.feedback")
  end)

  it("env block uses task_count_bucket, never the stale task_count integer", function()
    -- Direct regression for the "task_count: nil" bug the user hit.
    -- The build_payload renamed the field to task_count_bucket; the
    -- env block in open_github_issue needs to follow.
    local body = feedback._build_github_body({
      client = {
        plugin_version    = "v1.4.1",
        nvim_version      = "0.10.0",
        os                = "Linux",
        tw_version        = "3.4.2",
        backend           = "lua",
        task_count_bucket = "26-100",
        config_summary    = {},
      },
      report = {
        what_happened = "x", expected = "y", other = "z",
      },
    })
    assert.is_string(body)
    assert.is_truthy(body:find("task_count_bucket: 26-100", 1, true),
      "env block missing 'task_count_bucket: 26-100'; got:\n" .. body)
    assert.is_nil(body:find("task_count: nil", 1, true),
      "env block contains stale 'task_count: nil' field; got:\n" .. body)
  end)
end)
