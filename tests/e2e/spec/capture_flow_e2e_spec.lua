-- capture_flow_e2e_spec.lua — drives the real quick-capture user journey
-- against a live task CLI. Covers two tw tasks:
--   * 0f0b9bbf — the add interface is a buffer that starts in insert mode
--   * 978fb9d1 — the post-add notification echoes the start of the task
--     so the user can confirm the right thing went through

local TMP = os.getenv("TASKWARRIOR_E2E_TMP")
assert(TMP and TMP ~= "", "TASKWARRIOR_E2E_TMP not set — run via tests/e2e/run.sh")

local taskmd = require("taskwarrior.taskmd")

local function open_capture()
  require("taskwarrior").capture()
  vim.wait(100, function() return false end, 10)
  return vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
end

-- Fire the capture buffer's <CR> insert-mode mapping the way a user would.
local function press_enter(buf)
  local maps = vim.api.nvim_buf_get_keymap(buf, "i")
  for _, m in ipairs(maps) do
    if m.lhs == "<CR>" and m.callback then
      m.callback()
      return true
    end
  end
  return false
end

describe("e2e quick-capture flow", function()
  it("opens a floating buffer in insert mode (tw 0f0b9bbf)", function()
    -- :startinsert only engages when control returns to the input loop,
    -- which never happens inside this in-process spec — so the real UX is
    -- observed over RPC in a child nvim whose main loop is idle between
    -- requests. This proves a user invoking capture lands in insert mode.
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h:h")
    local sock = TMP .. "/capture-mode.sock"
    local job = vim.fn.jobstart({
      "nvim", "--headless", "--listen", sock, "--cmd", "set rtp+=" .. root,
    })
    assert.is_true(job > 0, "failed to spawn child nvim")
    vim.wait(3000, function() return vim.fn.filereadable(sock) == 1 end, 20)
    local chan = vim.fn.sockconnect("pipe", sock, { rpc = true })
    assert.is_true(chan > 0, "failed to connect to child nvim")

    vim.rpcrequest(chan, "nvim_exec_lua",
      "require('taskwarrior').setup({}) require('taskwarrior').capture()", {})
    -- Give the child a main-loop turn so the pending startinsert engages.
    vim.wait(300, function()
      return vim.rpcrequest(chan, "nvim_get_mode").mode:sub(1, 1) == "i"
    end, 20)

    local mode = vim.rpcrequest(chan, "nvim_get_mode").mode
    local is_float = vim.rpcrequest(chan, "nvim_exec_lua", [[
      local cfg = vim.api.nvim_win_get_config(0)
      return (cfg.relative ~= nil and cfg.relative ~= "")
        and vim.bo[vim.api.nvim_get_current_buf()].buftype == "nofile"
    ]], {})

    vim.fn.chanclose(chan)
    vim.fn.jobstop(job)

    assert.are.same("i", mode:sub(1, 1),
      "capture window did not start in insert mode (child mode: " .. mode .. ")")
    assert.is_true(is_float, "capture window is not a nofile float")
  end)

  it("submitting shows a snippet of the added task and stores it (tw 978fb9d1)", function()
    local buf, win = open_capture()
    local desc = ("capture snippet check %d"):format(math.random(1, 1e9))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { desc .. " project:capturetest" })

    local messages = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, ...) messages[#messages + 1] = tostring(msg) end

    assert.is_true(press_enter(buf), "capture <CR> mapping not found")
    vim.wait(3000, function()
      local t = taskmd.shell_export("project:capturetest")
      return t and #t > 0
    end, 20)
    vim.wait(200, function() return false end, 10)
    vim.notify = orig_notify

    -- Observable TW state: the task exists with parsed fields.
    local tasks = taskmd.shell_export("project:capturetest") or {}
    local stored
    for _, t in ipairs(tasks) do
      if t.description == desc then stored = t end
    end
    assert.is_truthy(stored, "captured task not found in export")

    -- Notification carries the first characters of the description.
    local prefix = desc:sub(1, 20)
    local mentioned = false
    for _, m in ipairs(messages) do
      if m:find(prefix, 1, true) then mentioned = true end
    end
    assert.is_true(mentioned,
      "no notification contained the task snippet; got: "
      .. vim.inspect(messages))
    pcall(vim.api.nvim_win_close, win, true)
  end)

  it("truncates long descriptions in the notification", function()
    local buf, win = open_capture()
    local long = ("verylongword "):rep(10) .. "tail-marker"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { long })

    local messages = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, ...) messages[#messages + 1] = tostring(msg) end
    assert.is_true(press_enter(buf), "capture <CR> mapping not found")
    vim.wait(3000, function() return #messages > 0 end, 20)
    vim.notify = orig_notify

    local added
    for _, m in ipairs(messages) do
      if m:find("added", 1, true) then added = m end
    end
    assert.is_truthy(added, "no 'added' notification; got " .. vim.inspect(messages))
    assert.is_truthy(added:find("…", 1, true),
      "long description was not truncated with an ellipsis: " .. added)
    assert.is_nil(added:find("tail-marker", 1, true),
      "notification should not contain the tail of a long description")
    pcall(vim.api.nvim_win_close, win, true)
  end)
end)
