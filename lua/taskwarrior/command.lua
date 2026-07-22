-- Central Taskwarrior process boundary.
--
-- Every plugin-owned `task` invocation should pass through this module. It
-- owns availability checks, non-interactive rc overrides, argv construction,
-- exit-status capture, and the result shape consumed by callers.

local M = {}

M.MUTATION_RC = { "rc.bulk=0", "rc.confirmation=off" }
M.READ_RC = {
  "rc.bulk=0",
  "rc.confirmation=off",
  "rc.verbose=nothing",
  "rc.color=off",
}

local function copy_list(values)
  local result = {}
  for _, value in ipairs(values or {}) do result[#result + 1] = tostring(value) end
  return result
end

function M.parse_args(text)
  if text == nil or text == "" then return {} end
  if type(text) == "table" then return copy_list(text) end
  if type(text) ~= "string" then
    return nil, "Taskwarrior arguments must be a string or list"
  end
  local args, current = {}, {}
  local quote, escaped, started = nil, false, false
  local function finish()
    if started then
      args[#args + 1] = table.concat(current)
      current, started = {}, false
    end
  end
  for i = 1, #text do
    local char = text:sub(i, i)
    if escaped then
      current[#current + 1] = char
      escaped, started = false, true
    elseif quote == "'" then
      if char == "'" then quote = nil else current[#current + 1] = char end
      started = true
    elseif quote == '"' then
      if char == '"' then
        quote = nil
      elseif char == "\\" then
        escaped = true
      else
        current[#current + 1] = char
      end
      started = true
    elseif char == "'" or char == '"' then
      quote, started = char, true
    elseif char == "\\" then
      escaped, started = true, true
    elseif char:match("%s") then
      finish()
    else
      current[#current + 1] = char
      started = true
    end
  end
  if escaped then return nil, "unfinished escape in Taskwarrior arguments" end
  if quote then return nil, "unclosed quote in Taskwarrior arguments" end
  finish()
  return args
end

local function accepted(code, ok_codes)
  if ok_codes == nil then return code == 0 end
  for _, allowed in ipairs(ok_codes) do
    if code == allowed then return true end
  end
  return false
end

local function build_argv(args, opts)
  local parsed, err = M.parse_args(args)
  if not parsed then return nil, err end
  local argv = { "task" }
  local rc = opts.rc
  if rc == nil then
    rc = opts.kind == "read" and M.READ_RC or M.MUTATION_RC
  end
  for _, value in ipairs(rc or {}) do argv[#argv + 1] = value end
  vim.list_extend(argv, parsed)
  return argv
end

local function failed_result(output, code, argv, reason)
  return {
    ok = false,
    output = output or "",
    code = code,
    argv = argv,
    reason = reason,
  }
end

--- Run Taskwarrior synchronously and return one stable result object.
--- opts.kind: "read" or "mutation" (mutation is the safe default).
--- opts.rc: explicit rc override list; {} disables defaults.
--- opts.ok_codes: accepted process exit codes (default {0}).
function M.run(args, opts)
  opts = opts or {}
  if not require("taskwarrior.runtime").ensure_available() then
    return failed_result("task executable is unavailable", 127, nil, "unavailable")
  end
  local argv, build_err = build_argv(args, opts)
  if not argv then return failed_result(build_err, -1, nil, "invalid-arguments") end
  local called, output = pcall(vim.fn.system, argv)
  if not called then return failed_result(tostring(output), -1, argv, "spawn-error") end
  local code = vim.v.shell_error
  return {
    ok = accepted(code, opts.ok_codes),
    output = output or "",
    code = code,
    argv = argv,
  }
end

function M.read(args, opts)
  opts = vim.tbl_extend("force", opts or {}, { kind = "read" })
  return M.run(args, opts)
end

function M.mutate(args, opts)
  opts = vim.tbl_extend("force", opts or {}, { kind = "mutation" })
  return M.run(args, opts)
end

--- Asynchronous Taskwarrior invocation with the same result contract.
function M.start(args, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  if not require("taskwarrior.runtime").ensure_available() then
    callback(failed_result("task executable is unavailable", 127, nil, "unavailable"))
    return nil
  end
  local argv, build_err = build_argv(args, opts)
  if not argv then
    callback(failed_result(build_err, -1, nil, "invalid-arguments"))
    return nil
  end
  local stdout, stderr = {}, {}
  local started, job = pcall(vim.fn.jobstart, argv, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data) if data then vim.list_extend(stdout, data) end end,
    on_stderr = function(_, data) if data then vim.list_extend(stderr, data) end end,
    on_exit = function(_, code)
      callback({
        ok = accepted(code, opts.ok_codes),
        output = table.concat(stdout, "\n"),
        stderr = table.concat(stderr, "\n"),
        code = code,
        argv = argv,
      })
    end,
  })
  if not started or job <= 0 then
    local detail = started and "failed to start task process" or tostring(job)
    callback(failed_result(detail, -1, argv, "spawn-error"))
    return nil
  end
  return job
end

return M
