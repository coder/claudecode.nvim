--- A command typed in Select mode, for example through a `<cmd>ClaudeCodeSend<CR>` mapping, has the same selection as
--- in Visual mode, so it must take the visual path.
require("tests.busted_setup")

describe("visual_commands in Select mode", function()
  local visual_commands
  local saved

  before_each(function()
    saved = { get_mode = vim.api.nvim_get_mode, feedkeys = vim.api.nvim_feedkeys, schedule = vim.schedule }
    vim.api.nvim_feedkeys = function() end
    vim.schedule = function(fn)
      fn()
    end
    package.loaded["claudecode.visual_commands"] = nil
    visual_commands = require("claudecode.visual_commands")
  end)

  after_each(function()
    vim.api.nvim_get_mode, vim.api.nvim_feedkeys, vim.schedule = saved.get_mode, saved.feedkeys, saved.schedule
  end)

  for name, mode in pairs({ charwise = "s", linewise = "S", blockwise = "\19" }) do
    it("runs the visual handler for a " .. name .. " Select-mode selection", function()
      vim.api.nvim_get_mode = function()
        return { mode = mode }
      end
      local ran
      local wrapped = visual_commands.create_visual_command_wrapper(function()
        ran = "normal"
      end, function()
        ran = "visual"
      end)

      wrapped()

      assert.are.equal("visual", ran)
    end)
  end
end)
