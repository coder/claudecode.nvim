-- snacks.nvim picker fixture for issue #192.
--
-- Demonstrates BOTH integration paths for adding a picker's selected/highlighted
-- file(s) to Claude Code's context:
--
--   1. WORKAROUND (works TODAY, no claudecode.nvim change): a custom snacks picker
--      `action` (`claude_add`) bound to <c-o> in the input AND list windows. This
--      is the idiomatic snacks way and works from the input box in insert mode.
--      It mirrors how the community claude-fzf.nvim plugin integrates fzf-lua.
--
--   2. Built-in command path: `:ClaudeCodeTreeAdd` also works when the picker
--      LIST window is focused (vim.bo.filetype == "snacks_picker_list"), via the
--      in-core snacks_picker_list handler in lua/claudecode/integrations.lua.
return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  ---@type snacks.Config
  opts = {
    picker = {
      enabled = true,
      ---@type table<string, snacks.picker.Action.spec>
      actions = {
        -- WORKAROUND action: send the selected (Tab) items, or the item under
        -- the cursor when nothing is selected, to Claude as @-mentions.
        claude_add = function(picker)
          local items = picker:selected({ fallback = true })
          local claudecode = require("claudecode")
          local count = 0
          for _, item in ipairs(items) do
            local path = Snacks.picker.util.path(item)
            if path and path ~= "" then
              local ok = claudecode.send_at_mention(path, nil, nil, "snacks-picker")
              if ok then
                count = count + 1
              end
            end
          end
          picker:close()
          vim.schedule(function()
            vim.notify(("[claude_add] Added %d file(s) to Claude context"):format(count), vim.log.levels.INFO)
          end)
        end,
      },
      win = {
        input = {
          keys = {
            ["<c-o>"] = { "claude_add", mode = { "i", "n" }, desc = "Add to Claude Code" },
          },
        },
        list = {
          keys = {
            ["<c-o>"] = { "claude_add", desc = "Add to Claude Code" },
          },
        },
      },
    },
  },
  keys = {
    {
      "<leader>ff",
      function()
        Snacks.picker.files()
      end,
      desc = "Find Files (snacks picker)",
    },
    {
      "<leader>fg",
      function()
        Snacks.picker.grep()
      end,
      desc = "Grep (snacks picker)",
    },
  },
}
