require("tests.busted_setup")
require("tests.mocks.vim")

describe("ClaudeCode command arguments integration", function()
  local claudecode
  local mock_server
  local mock_lockfile
  local mock_selection
  local executed_commands
  local original_require

  before_each(function()
    executed_commands = {}

    -- Mock vim.fn.termopen to capture actual commands
    vim.fn.termopen = spy.new(function(cmd, opts)
      table.insert(executed_commands, {
        cmd = cmd,
        opts = opts,
      })
      return 123 -- mock job id
    end)

    vim.fn.mode = function()
      return "n"
    end

    vim.o = {
      columns = 120,
      lines = 30,
    }

    vim.api.nvim_feedkeys = spy.new(function() end)
    vim.api.nvim_replace_termcodes = spy.new(function(str)
      return str
    end)
    vim.api.nvim_create_user_command = spy.new(function() end)
    vim.api.nvim_create_autocmd = spy.new(function() end)
    vim.api.nvim_create_augroup = spy.new(function()
      return 1
    end)
    vim.api.nvim_get_current_win = spy.new(function()
      return 1
    end)
    vim.api.nvim_win_set_height = spy.new(function() end)
    vim.api.nvim_win_call = spy.new(function(winid, func)
      func()
    end)
    vim.api.nvim_get_current_buf = spy.new(function()
      return 1
    end)
    vim.api.nvim_win_close = spy.new(function() end)
    vim.cmd = spy.new(function() end)
    vim.bo = setmetatable({}, {
      __index = function()
        return {}
      end,
      __newindex = function() end,
    })
    vim.schedule = function(func)
      func()
    end

    mock_server = {
      start = function()
        return true, 12345
      end,
      stop = function()
        return true
      end,
      state = { port = 12345 },
    }

    mock_lockfile = {
      create = function()
        return true, "/mock/path"
      end,
      remove = function()
        return true
      end,
    }

    mock_selection = {
      enable = function() end,
      disable = function() end,
    }

    original_require = _G.require
    _G.require = function(mod)
      if mod == "claudecode.server.init" then
        return mock_server
      elseif mod == "claudecode.lockfile" then
        return mock_lockfile
      elseif mod == "claudecode.selection" then
        return mock_selection
      elseif mod == "claudecode.config" then
        return {
          apply = function(opts)
            return vim.tbl_deep_extend("force", {
              port_range = { min = 10000, max = 65535 },
              auto_start = false,
              terminal_cmd = nil,
              log_level = "info",
              track_selection = true,
              visual_demotion_delay_ms = 50,
              diff_opts = {
                auto_close_on_accept = true,
                show_diff_stats = true,
                vertical_split = true,
                open_in_current_tab = false,
              },
            }, opts or {})
          end,
        }
      elseif mod == "claudecode.diff" then
        return {
          setup = function() end,
        }
      elseif mod == "claudecode.logger" then
        return {
          setup = function() end,
          debug = function() end,
          error = function() end,
          warn = function() end,
        }
      else
        return original_require(mod)
      end
    end

    -- Clear package cache to ensure fresh requires
    package.loaded["claudecode"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.terminal.snacks"] = nil
    package.loaded["claudecode.terminal.native"] = nil
    claudecode = require("claudecode")
  end)

  after_each(function()
    _G.require = original_require
    package.loaded["claudecode"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.terminal.snacks"] = nil
    package.loaded["claudecode.terminal.native"] = nil
  end)

  describe("with native terminal provider", function()
    it("should execute terminal command with appended arguments", function()
      claudecode.setup({
        auto_start = false,
        terminal_cmd = "test_claude_cmd",
        terminal = { provider = "native" },
      })

      -- Find and execute the ClaudeCode command
      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCode" then
          command_handler = call.vals[2]
          break
        end
      end

      assert.is_function(command_handler, "ClaudeCode command handler should exist")

      command_handler({ args = "--resume --verbose" })

      -- Verify the command was called with arguments
      assert.is_true(#executed_commands > 0, "No terminal commands were executed")
      local last_cmd = executed_commands[#executed_commands]

      -- For native terminal, cmd should be a table
      if type(last_cmd.cmd) == "table" then
        local cmd_string = table.concat(last_cmd.cmd, " ")
        assert.is_true(cmd_string:find("test_claude_cmd") ~= nil, "Base command not found in: " .. cmd_string)
        assert.is_true(cmd_string:find("--resume") ~= nil, "Arguments not found in: " .. cmd_string)
        assert.is_true(cmd_string:find("--verbose") ~= nil, "Arguments not found in: " .. cmd_string)
      else
        assert.is_true(last_cmd.cmd:find("test_claude_cmd") ~= nil, "Base command not found")
        assert.is_true(last_cmd.cmd:find("--resume") ~= nil, "Arguments not found")
        assert.is_true(last_cmd.cmd:find("--verbose") ~= nil, "Arguments not found")
      end
    end)

    it("should work with default claude command and arguments", function()
      claudecode.setup({
        auto_start = false,
        terminal = { provider = "native" },
      })

      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCodeOpen" then
          command_handler = call.vals[2]
          break
        end
      end

      command_handler({ args = "--help" })

      assert.is_true(#executed_commands > 0, "No terminal commands were executed")
      local last_cmd = executed_commands[#executed_commands]

      local cmd_string = type(last_cmd.cmd) == "table" and table.concat(last_cmd.cmd, " ") or last_cmd.cmd
      assert.is_true(cmd_string:find("claude") ~= nil, "Default claude command not found")
      assert.is_true(cmd_string:find("--help") ~= nil, "Arguments not found")
    end)

    it("should handle empty arguments gracefully", function()
      claudecode.setup({
        auto_start = false,
        terminal_cmd = "claude",
        terminal = { provider = "native" },
      })

      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCode" then
          command_handler = call.vals[2]
          break
        end
      end

      command_handler({ args = "" })

      assert.is_true(#executed_commands > 0, "No terminal commands were executed")
      local last_cmd = executed_commands[#executed_commands]

      local cmd_string = type(last_cmd.cmd) == "table" and table.concat(last_cmd.cmd, " ") or last_cmd.cmd
      assert.is_true(
        cmd_string == "claude" or cmd_string:find("^claude$") ~= nil,
        "Command should be just 'claude' without extra arguments"
      )
    end)
  end)

  describe("edge cases", function()
    it("should handle special characters in arguments", function()
      claudecode.setup({
        auto_start = false,
        terminal_cmd = "claude",
        terminal = { provider = "native" },
      })

      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCode" then
          command_handler = call.vals[2]
          break
        end
      end

      command_handler({ args = "--message='hello world' --path=/tmp/test" })

      assert.is_true(#executed_commands > 0, "No terminal commands were executed")
      local last_cmd = executed_commands[#executed_commands]

      local cmd_string = type(last_cmd.cmd) == "table" and table.concat(last_cmd.cmd, " ") or last_cmd.cmd
      assert.is_true(cmd_string:find("--message='hello world'") ~= nil, "Special characters not preserved")
      assert.is_true(cmd_string:find("--path=/tmp/test") ~= nil, "Path arguments not preserved")
    end)

    it("should handle very long argument strings", function()
      claudecode.setup({
        auto_start = false,
        terminal_cmd = "claude",
        terminal = { provider = "native" },
      })

      local long_args = string.rep("--flag ", 50) .. "--final"

      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCode" then
          command_handler = call.vals[2]
          break
        end
      end

      command_handler({ args = long_args })

      assert.is_true(#executed_commands > 0, "No terminal commands were executed")
      local last_cmd = executed_commands[#executed_commands]

      local cmd_string = type(last_cmd.cmd) == "table" and table.concat(last_cmd.cmd, " ") or last_cmd.cmd
      assert.is_true(cmd_string:find("--final") ~= nil, "Long arguments not preserved")
    end)
  end)

  describe("backward compatibility", function()
    it("should not break existing calls without arguments", function()
      claudecode.setup({
        auto_start = false,
        terminal_cmd = "claude",
        terminal = { provider = "native" },
      })

      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCode" then
          command_handler = call.vals[2]
          break
        end
      end

      command_handler({})

      assert.is_true(#executed_commands > 0, "No terminal commands were executed")
      local last_cmd = executed_commands[#executed_commands]

      local cmd_string = type(last_cmd.cmd) == "table" and table.concat(last_cmd.cmd, " ") or last_cmd.cmd
      assert.is_true(cmd_string == "claude" or cmd_string:find("^claude$") ~= nil, "Should work exactly as before")
    end)

    it("should maintain existing ClaudeCodeClose command functionality", function()
      claudecode.setup({ auto_start = false })

      local close_command_found = false
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCodeClose" then
          close_command_found = true
          local config = call.vals[3]
          assert.is_nil(config.nargs, "ClaudeCodeClose should not accept arguments")
          break
        end
      end

      assert.is_true(close_command_found, "ClaudeCodeClose command should still be registered")
    end)
  end)
end)
