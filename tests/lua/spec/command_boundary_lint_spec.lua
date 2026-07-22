-- Guard the centralized Taskwarrior process boundary. Plugin-owned commands
-- belong in taskwarrior.command so availability, rc flags, argv safety, and
-- exit handling cannot drift independently again.

describe("Taskwarrior command boundary", function()
  it("has no direct task subprocess calls outside approved boundaries", function()
    local source = debug.getinfo(1, "S").source:sub(2)
    local repo_root = vim.fn.fnamemodify(source, ":h:h:h:h")
    local allowed = {
      ["lua/taskwarrior/command.lua"] = true,
      -- Tutor validators intentionally use the isolated argv prefix created
      -- by tutor/init.lua; routing them through the normal command boundary
      -- would point them at the user's real Taskwarrior database.
      ["lua/taskwarrior/tutor/lessons.lua"] = true,
      -- Non-Taskwarrior subprocesses: backup `cp`, Git metadata, browser and
      -- GitHub helpers. These are reviewed separately from the task boundary.
      ["lua/taskwarrior/apply.lua"] = true,
      ["lua/taskwarrior/feedback.lua"] = true,
    }
    local offenders = {}
    local files = vim.fn.glob(repo_root .. "/lua/**/*.lua", true, true)
    for _, file in ipairs(files) do
      local relative = file:gsub(repo_root .. "/", "")
      if not allowed[relative] then
        local fh = io.open(file, "r")
        if fh then
          local content = fh:read("*all")
          fh:close()
          local direct_process = content:match("vim%.fn%.system%s*%(")
            or content:match("vim%.fn%.systemlist%s*%(")
            or content:match("vim%.fn%.jobstart%s*%(")
          if direct_process then
            offenders[#offenders + 1] = relative
          end
        end
      end
    end
    assert.are.same({}, offenders,
      "route Taskwarrior subprocesses through require('taskwarrior.command')")
  end)
end)
