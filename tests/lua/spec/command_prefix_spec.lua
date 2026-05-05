-- tests/lua/spec/command_prefix_spec.lua
--
-- Configurable :Task* command prefix (issue #1).
--
-- Default: prefix = "Task", commands are :Task, :TaskFilter, :TaskAdd, ...
-- Override: vim.g.taskwarrior_command_prefix = "Tw" → :Tw, :TwFilter, :TwAdd, ...
--
-- The lazy entrypoint in plugin/taskwarrior.lua reads vim.g (because it
-- runs before setup()). The full command set in lua/taskwarrior/commands.lua
-- reads config.options (set during setup()). setup() reconciles them so
-- both sources stay in sync.

local function clear_user_commands()
  -- Best-effort wipe of any commands left by a prior test in this spec.
  -- Includes "Foo" since one test registers :Foo* via an arbitrary prefix
  -- and stale :FooFilter/etc. would leak into later tests.
  for _, name in ipairs({
    "Task", "TaskFilter", "TaskAdd", "TaskHelp", "TaskTutor",
    "Tw",   "TwFilter",   "TwAdd",   "TwHelp",   "TwTutor",
    "Foo",  "FooFilter",  "FooAdd",  "FooHelp",  "FooTutor",
  }) do
    pcall(vim.api.nvim_del_user_command, name)
  end
end

describe("command_prefix — issue #1 (configurable command names)", function()
  local original_g

  before_each(function()
    original_g = vim.g.taskwarrior_command_prefix
    vim.g.taskwarrior_command_prefix = nil
    package.loaded["taskwarrior"] = nil
    package.loaded["taskwarrior.config"] = nil
    package.loaded["taskwarrior.commands"] = nil
    clear_user_commands()
  end)

  after_each(function()
    vim.g.taskwarrior_command_prefix = original_g
    clear_user_commands()
  end)

  describe("default behavior — :Tw* (changed from :Task* in v1.4.1)", function()
    it("with no override, registers commands under the Tw* namespace", function()
      require("taskwarrior").setup({})
      local cmds = vim.api.nvim_get_commands({})
      assert.is_not_nil(cmds.Tw,       ":Tw should be registered by default")
      assert.is_not_nil(cmds.TwFilter, ":TwFilter should be registered by default")
      assert.is_not_nil(cmds.TwHelp,   ":TwHelp should be registered by default")
      -- And :Task* should NOT be present unless the user opts in.
      assert.is_nil(cmds.TaskFilter,
        ":TaskFilter should NOT be registered by default after the v1.4.1 flip")
    end)

    it("config.options.command_prefix defaults to 'Tw'", function()
      require("taskwarrior").setup({})
      assert.equals("Tw", require("taskwarrior.config").options.command_prefix)
    end)
  end)

  describe("override via vim.g.taskwarrior_command_prefix", function()
    it("'Task' (legacy) → commands revert to :Task*", function()
      -- The reverse of the new default: existing users who want their
      -- old keymaps back set vim.g.taskwarrior_command_prefix = "Task".
      vim.g.taskwarrior_command_prefix = "Task"
      require("taskwarrior").setup({})
      local cmds = vim.api.nvim_get_commands({})
      assert.is_not_nil(cmds.Task,        ":Task should be registered with prefix=Task")
      assert.is_not_nil(cmds.TaskFilter,  ":TaskFilter should be registered with prefix=Task")
      assert.is_nil(cmds.TwFilter,
        ":TwFilter should NOT be registered when user explicitly opts back to Task")
    end)

    it("vim.g override propagates into config.options.command_prefix", function()
      vim.g.taskwarrior_command_prefix = "Task"
      require("taskwarrior").setup({})
      assert.equals("Task", require("taskwarrior.config").options.command_prefix)
    end)

    it("arbitrary prefix 'Foo' works too", function()
      vim.g.taskwarrior_command_prefix = "Foo"
      require("taskwarrior").setup({})
      local cmds = vim.api.nvim_get_commands({})
      assert.is_not_nil(cmds.Foo,       ":Foo should be registered with prefix=Foo")
      assert.is_not_nil(cmds.FooFilter, ":FooFilter should be registered")
    end)
  end)

  describe("override via setup() option", function()
    it("setup({ command_prefix = 'Task' }) → :Task* registered", function()
      require("taskwarrior").setup({ command_prefix = "Task" })
      local cmds = vim.api.nvim_get_commands({})
      assert.is_not_nil(cmds.Task,       ":Task should be registered with config prefix=Task")
      assert.is_not_nil(cmds.TaskFilter, ":TaskFilter should be registered")
      assert.is_nil(cmds.TwFilter,
        ":TwFilter should NOT be registered when prefix=Task")
    end)

    it("vim.g wins when both are set (vim.g is the user-explicit override)", function()
      vim.g.taskwarrior_command_prefix = "Tw"
      require("taskwarrior").setup({ command_prefix = "Foo" })
      assert.equals("Tw", require("taskwarrior.config").options.command_prefix)
      local cmds = vim.api.nvim_get_commands({})
      assert.is_not_nil(cmds.TwFilter, "vim.g override should win")
      assert.is_nil(cmds.FooFilter, "config-passed prefix should NOT win against vim.g")
    end)
  end)

  describe("validation", function()
    it("rejects an empty prefix", function()
      local ok, err = pcall(function()
        require("taskwarrior").setup({ command_prefix = "" })
      end)
      assert.is_false(ok, "empty prefix must error")
      assert.is_truthy(tostring(err):lower():match("prefix"),
        "error should mention 'prefix'; got: " .. tostring(err))
    end)

    it("rejects a prefix not starting with uppercase letter", function()
      local ok = pcall(function()
        require("taskwarrior").setup({ command_prefix = "task" })
      end)
      assert.is_false(ok, "lowercase prefix must error (Vim command names need leading uppercase)")
    end)

    it("rejects a prefix with non-letters", function()
      local ok = pcall(function()
        require("taskwarrior").setup({ command_prefix = "Task1" })
      end)
      assert.is_false(ok, "prefix with digits must error")
    end)
  end)

  describe("collision detection", function()
    it("warns once when :<prefix> is already defined", function()
      -- Pretend some other plugin already registered :Tw (the new default
      -- prefix as of v1.4.1). Pre-flip this would have used :Task to
      -- mimic Shatur/neovim-tasks; with :Tw as default, we collide on :Tw.
      vim.api.nvim_create_user_command("Tw", function() end, { nargs = "*" })

      local notifications = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level, _opts)
        table.insert(notifications, { msg = tostring(msg), level = level })
      end

      require("taskwarrior").setup({})

      vim.notify = original_notify

      -- Find the collision warning.
      local count = 0
      for _, n in ipairs(notifications) do
        if n.level == vim.log.levels.WARN and n.msg:match("[Cc]ollision")
          and n.msg:match("[Tt]askwarrior") then
          count = count + 1
        end
      end
      assert(count == 1, "expected exactly 1 collision WARN, got " .. count
        .. ":\n" .. vim.inspect(notifications))
    end)

    it("collision warning mentions the override mechanism", function()
      -- Pre-create :Tw to match the new default prefix; otherwise
      -- setup() doesn't see a collision and never warns. (The earlier
      -- replace_all when flipping the default missed this second
      -- occurrence because of slightly different surrounding context.)
      vim.api.nvim_create_user_command("Tw", function() end, { nargs = "*" })

      local found_msg
      local original_notify = vim.notify
      vim.notify = function(msg, level, _opts)
        if level == vim.log.levels.WARN and tostring(msg):match("[Cc]ollision") then
          found_msg = tostring(msg)
        end
      end

      require("taskwarrior").setup({})
      vim.notify = original_notify

      assert.is_truthy(found_msg, "no collision warning fired")
      assert.is_truthy(found_msg:match("taskwarrior_command_prefix")
        or found_msg:match("command_prefix"),
        "collision warning should tell the user how to override; got: " .. found_msg)
    end)

    it("no warning when there's no collision", function()
      local notifications = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level, _opts)
        table.insert(notifications, { msg = tostring(msg), level = level })
      end

      require("taskwarrior").setup({})

      vim.notify = original_notify
      for _, n in ipairs(notifications) do
        assert.is_falsy(
          n.level == vim.log.levels.WARN and n.msg:match("[Cc]ollision"),
          "false-positive collision warning: " .. n.msg
        )
      end
    end)
  end)
end)
