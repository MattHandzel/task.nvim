-- taskwarrior/sync.lua — :TaskSync. Thin wrapper around `task sync` that
-- reports progress via vim.notify, parses common error shapes (no server
-- configured, auth failure), and offers a one-key retry.
--
-- This only touches Taskwarrior 3.x's native sync. Older taskd/taskserver
-- setups also use `task sync`, so the wrapper works for both.

local M = {}
local command = require("taskwarrior.command")

function M.run()
  local notify = require("taskwarrior.notify")
  notify("apply", "taskwarrior.nvim: syncing…")
  command.start({ "sync" }, { kind = "mutation" },
    function(result)
      local out = result.output or ""
      local err = result.stderr or ""
      if result.ok then
        local summary = (out .. "\n" .. err):gsub("^%s+", ""):gsub("%s+$", "")
        if summary == "" then summary = "sync complete" end
        notify("apply", "taskwarrior.nvim: " .. summary:sub(1, 200))
        -- Refresh every open task buffer so the UI reflects any remote updates.
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_valid(b) and vim.b[b].task_filter ~= nil then
            pcall(function() require("taskwarrior.buffer").refresh_buf(b) end)
          end
        end
        return
      end
      -- Try to explain common failure modes.
      local hint = ""
      local combined = (out .. "\n" .. err):lower()
      if combined:match("no server") or combined:match("not configured") then
        hint = "\n(hint: configure sync.server.url and sync.encryption_secret in ~/.taskrc)"
      elseif combined:match("auth") or combined:match("credential") then
        hint = "\n(hint: authentication failed — check sync credentials)"
      end
      notify("error",
        "taskwarrior.nvim: sync failed (exit " .. result.code .. ")\n"
          .. (err ~= "" and err or out) .. hint,
        vim.log.levels.ERROR)
      vim.ui.select({ "retry", "cancel" }, { prompt = "taskwarrior.nvim:" },
        function(choice) if choice == "retry" then M.run() end end)
    end)
end

return M
