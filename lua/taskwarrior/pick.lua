-- taskwarrior/pick.lua — one way to choose from a finite set.
--
-- Everything with a small, known set of answers (sort spec, grouping,
-- context, saved view, report) goes through here instead of a free-text
-- `vim.fn.input`. Typing `urgency-` from memory is not a feature.
--
-- Built on `vim.ui.select`, deliberately: that routes through whatever
-- picker the user already configured — telescope/dressing, snacks, fzf-lua
-- — so fuzzy matching comes from their own tooling and matches the rest of
-- their editor. With no backend installed it degrades to Neovim's built-in
-- numbered list, which still works.

local M = {}

--- Choose from `entries` ({ value, label } tables, or plain strings).
--- opts.prompt   — picker prompt.
--- opts.current  — value to mark as active.
--- on_choice(value, entry) fires only on a real selection (never on cancel).
function M.select(entries, opts, on_choice)
  opts = opts or {}
  local items = {}
  for _, e in ipairs(entries) do
    if type(e) == "string" then
      items[#items + 1] = { value = e, label = e }
    else
      items[#items + 1] = e
    end
  end
  if #items == 0 then
    require("taskwarrior.notify")("warn",
      opts.empty_message or "taskwarrior.nvim: nothing to choose from",
      vim.log.levels.WARN)
    return
  end

  vim.ui.select(items, {
    prompt = opts.prompt or "Select:",
    format_item = function(item)
      local label = item.label or item.value
      -- Mark the active entry so the picker doubles as "what is set now?".
      if opts.current ~= nil and item.value == opts.current then
        return "● " .. label
      end
      return "  " .. label
    end,
  }, function(choice)
    if not choice then return end
    on_choice(choice.value, choice)
  end)
end

return M
