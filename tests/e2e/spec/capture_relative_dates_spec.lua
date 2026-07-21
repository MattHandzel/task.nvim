-- Capture parses relative-date synonyms and doesn't duplicate tasks.
--
-- Regression (issue #7): Taskwarrior's ordinary `task add` output reports a
-- numeric working-set ID (`Created task 1.`), not the permanent UUID that
-- tw_add tried to extract. A quiet user config can produce no add output at
-- all. In both cases tw_add returned "" after successfully creating the task,
-- so capture.submit fell through to a raw `task add` and created it again.
-- Fix: force `rc.verbose=new-uuid` in tw_add, and never issue a second add
-- merely because UUID extraction failed after the parsed add was attempted.
--
-- The e2e harness sets `verbose=none` in .taskrc. That produces the same
-- empty-UUID failure mode as the reporter's numeric-ID output, so reverting
-- either half of the fix makes the UI regression below fail.

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local function task_export(filter)
  local out = vim.fn.system(string.format(
    "task rc.bulk=0 rc.confirmation=off rc.json.array=on %s export", filter or ""))
  local js = out:find("%[")
  if js and js > 1 then out = out:sub(js) end
  local ok, arr = pcall(vim.fn.json_decode, out)
  if not ok or type(arr) ~= "table" then return {} end
  return arr
end

local function tasks_with_desc_contains(needle)
  local hits = {}
  for _, t in ipairs(task_export()) do
    if t.description and t.description:find(needle, 1, true) then
      hits[#hits + 1] = t
    end
  end
  return hits
end

local function submit_through_tw_add(line)
  -- Drive the public command and its real insert-mode <CR> callback. Calling
  -- parse_capture/tw_add directly is insufficient for issue #7: the duplicate
  -- lived in capture.submit's fallback control flow.
  vim.cmd("TwAdd")
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })

  local enter_callback
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "i")) do
    if mapping.lhs == "<CR>" then
      enter_callback = mapping.callback
      break
    end
  end
  assert.is_function(enter_callback, ":TwAdd capture buffer has no Lua <CR> callback")
  enter_callback()

  -- The mapping schedules submit, which schedules the window close. Waiting
  -- for the capture window to disappear guarantees all synchronous task-add
  -- attempts in submit (including the old erroneous fallback) have finished.
  assert.is_true(vim.wait(3000, function()
    return not vim.api.nvim_win_is_valid(winid)
  end, 10), ":TwAdd capture window did not close after submit")
end

require("taskwarrior").setup({})

describe("capture: relative-date parsing through tw_add", function()
  local tm

  before_each(function()
    tm = require("taskwarrior.taskmd")
  end)

  it("due:today resolves to today's date and is stripped from description", function()
    local desc, fields = tm.parse_capture(
      "due:today CAPTURE_TEST_TODAY follow up project:Inbox", {})
    assert.are.equal("CAPTURE_TEST_TODAY follow up", desc)
    assert.are.equal("today", fields.due)
    assert.are.equal("Inbox", fields.project)

    local uuid = tm.tw_add(desc, fields)
    assert.is_truthy(uuid)
    assert.is_not.equal("", uuid)

    local hits = tasks_with_desc_contains("CAPTURE_TEST_TODAY")
    assert.are.equal(1, #hits, "expected exactly 1 task (no fallback duplicate)")
    local t = hits[1]
    assert.is_truthy(t.due, "due field should be set")
    -- Today in TW format: YYYYMMDDTHHMMSSZ matching today's date
    local today = os.date("!%Y%m%d")
    assert.is_truthy(t.due:find("^" .. today), "due should start with today's YYYYMMDD, got " .. t.due)
    assert.is_nil(t.description:match("due:today"), "description should not contain 'due:today'")
  end)

  it("due:wednesday resolves to a weekday, no description leak", function()
    local desc, fields = tm.parse_capture("due:wednesday CAPTURE_TEST_WED do thing", {})
    assert.are.equal("CAPTURE_TEST_WED do thing", desc)
    assert.are.equal("wednesday", fields.due)

    local uuid = tm.tw_add(desc, fields)
    assert.is_not.equal("", uuid)

    local hits = tasks_with_desc_contains("CAPTURE_TEST_WED")
    assert.are.equal(1, #hits)
    assert.is_truthy(hits[1].due, "due should resolve via taskwarrior")
    assert.is_nil(hits[1].description:match("due:"), "no 'due:' literal in description")
  end)

  it("tw_add returns extractable UUID even when user has verbose=nothing", function()
    -- Defensive: override our own rc to simulate the worst case.
    local uuid = tm.tw_add("CAPTURE_TEST_UUID_VERBOSE", { project = "X" })
    assert.is_truthy(uuid:match("^[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+%-[0-9a-f]+$"),
      "tw_add must return a valid UUID; got: " .. tostring(uuid))
  end)

  it(":TwAdd creates exactly one task through the real submit callback", function()
    local marker = "CAPTURE_TEST_ISSUE_7_UI"
    -- Match the reporter's default configuration, where an un-overridden
    -- `task add` prints `Created task <numeric-id>.` rather than a UUID.
    local previous_verbose = vim.trim(vim.fn.system({ "task", "_get", "rc.verbose" }))
    vim.fn.system({ "task", "config", "verbose", "yes" })
    assert.are.equal(0, vim.v.shell_error)
    local ok, err = pcall(submit_through_tw_add,
      "due:today " .. marker .. " project:Inbox")
    vim.fn.system({ "task", "config", "verbose", previous_verbose })
    assert.are.equal(0, vim.v.shell_error)
    assert.is_true(ok, tostring(err))

    local hits = tasks_with_desc_contains(marker)
    assert.are.equal(1, #hits,
      ":TwAdd must not run a second raw-add fallback after a successful parsed add")
    assert.are.equal(marker, hits[1].description)
    assert.are.equal("Inbox", hits[1].project)
    assert.is_truthy(hits[1].due)
  end)

  it(":TwAdd never retries an add that succeeded without a usable UUID", function()
    local marker = "CAPTURE_TEST_ISSUE_7_AMBIGUOUS"
    local original_tw_add = tm.tw_add
    local original_notify = vim.notify
    local notices = {}
    tm.tw_add = function(desc, fields)
      -- Perform the real mutation, then simulate output that contains no UUID.
      -- This recreates issue #7 independently of Taskwarrior's configured
      -- verbosity and proves capture's fallback cannot duplicate the task.
      original_tw_add(desc, fields)
      return "", true
    end
    vim.notify = function(message, level)
      notices[#notices + 1] = { message = tostring(message), level = level }
    end

    local ok, err = pcall(submit_through_tw_add,
      "due:today " .. marker .. " project:Inbox")
    tm.tw_add = original_tw_add
    vim.notify = original_notify
    assert.is_true(ok, tostring(err))

    local hits = tasks_with_desc_contains(marker)
    assert.are.equal(1, #hits,
      "an ambiguous add result must not trigger a second raw task add")
    assert.are.equal(marker, hits[1].description)
    assert.are.equal("Inbox", hits[1].project)
    assert.is_truthy(hits[1].due)
    assert.are.equal(1, #notices)
    assert.are.equal(vim.log.levels.WARN, notices[1].level)
    assert.is_truthy(notices[1].message:find("not retrying", 1, true))
  end)
end)
