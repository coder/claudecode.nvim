require("tests.busted_setup")
require("tests.mocks.vim")

describe("ClaudeCodeAdd command", function()
  local claudecode
  local mock_server
  local mock_logger
  local saved_require = _G.require

  local function setup_mocks()
    mock_server = {
      broadcast = spy.new(function()
        return true
      end),
    }

    mock_logger = {
      setup = function() end,
      debug = spy.new(function() end),
      error = spy.new(function() end),
      warn = spy.new(function() end),
    }

    -- Override vim.fn functions for our specific tests
    vim.fn.expand = spy.new(function(path)
      if path == "~/test.lua" then
        return "/home/user/test.lua"
      elseif path == "./relative.lua" then
        return "/current/dir/relative.lua"
      end
      return path
    end)

    vim.fn.filereadable = spy.new(function(path)
      if path == "/existing/file.lua" or path == "/home/user/test.lua" then
        return 1
      end
      return 0
    end)

    vim.fn.isdirectory = spy.new(function(path)
      if path == "/existing/dir" or path == "/current/dir/relative.lua" then
        return 1
      end
      return 0
    end)

    vim.fn.getcwd = function()
      return "/current/dir"
    end

    vim.api.nvim_create_user_command = spy.new(function() end)
    vim.api.nvim_buf_get_name = function()
      return "test.lua"
    end

    vim.bo = { filetype = "lua" }
    vim.notify = spy.new(function() end)

    _G.require = function(mod)
      if mod == "claudecode.logger" then
        return mock_logger
      elseif mod == "claudecode.config" then
        return {
          apply = function(opts)
            return opts or {}
          end,
        }
      elseif mod == "claudecode.diff" then
        return {
          setup = function() end,
        }
      elseif mod == "claudecode.terminal" then
        return {
          setup = function() end,
        }
      elseif mod == "claudecode.visual_commands" then
        return {
          create_visual_command_wrapper = function(normal_handler, visual_handler)
            return normal_handler
          end,
        }
      else
        return saved_require(mod)
      end
    end
  end

  before_each(function()
    setup_mocks()

    -- Clear package cache to ensure fresh require
    package.loaded["claudecode"] = nil
    package.loaded["claudecode.config"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.diff"] = nil
    package.loaded["claudecode.visual_commands"] = nil
    package.loaded["claudecode.terminal"] = nil

    claudecode = require("claudecode")

    -- Set up the server state manually for testing
    claudecode.state.server = mock_server
    claudecode.state.port = 12345
  end)

  after_each(function()
    _G.require = saved_require
    package.loaded["claudecode"] = nil
  end)

  describe("command registration", function()
    it("should register ClaudeCodeAdd command during setup", function()
      claudecode.setup({ auto_start = false })

      -- Find the ClaudeCodeAdd command registration
      local add_command_found = false
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCodeAdd" then
          add_command_found = true

          -- Check command configuration
          local config = call.vals[3]
          assert.is_equal(1, config.nargs)
          assert.is_equal("file", config.complete)
          assert.is_string(config.desc)
          break
        end
      end

      assert.is_true(add_command_found, "ClaudeCodeAdd command was not registered")
    end)
  end)

  describe("command execution", function()
    local command_handler

    before_each(function()
      claudecode.setup({ auto_start = false })

      -- Extract the command handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCodeAdd" then
          command_handler = call.vals[2]
          break
        end
      end

      assert.is_function(command_handler, "Command handler should be a function")
    end)

    describe("validation", function()
      it("should error when server is not running", function()
        claudecode.state.server = nil

        command_handler({ args = "/existing/file.lua" })

        assert.spy(mock_logger.error).was_called()
        assert.spy(vim.notify).was_called()
      end)

      it("should error when no file path is provided", function()
        command_handler({ args = "" })

        assert.spy(mock_logger.error).was_called()
        assert.spy(vim.notify).was_called()
      end)

      it("should error when file does not exist", function()
        command_handler({ args = "/nonexistent/file.lua" })

        assert.spy(mock_logger.error).was_called()
        assert.spy(vim.notify).was_called()
      end)
    end)

    describe("path handling", function()
      it("should expand tilde paths", function()
        command_handler({ args = "~/test.lua" })

        assert.spy(vim.fn.expand).was_called_with("~/test.lua")
        assert.spy(mock_server.broadcast).was_called()
      end)

      it("should expand relative paths", function()
        command_handler({ args = "./relative.lua" })

        assert.spy(vim.fn.expand).was_called_with("./relative.lua")
        assert.spy(mock_server.broadcast).was_called()
      end)

      it("should handle absolute paths", function()
        command_handler({ args = "/existing/file.lua" })

        assert.spy(mock_server.broadcast).was_called()
      end)
    end)

    describe("broadcasting", function()
      it("should broadcast existing file successfully", function()
        command_handler({ args = "/existing/file.lua" })

        assert.spy(mock_server.broadcast).was_called_with("at_mentioned", {
          filePath = "/existing/file.lua",
          lineStart = nil,
          lineEnd = nil,
        })
        assert.spy(mock_logger.debug).was_called()
      end)

      it("should broadcast existing directory successfully", function()
        command_handler({ args = "/existing/dir" })

        assert.spy(mock_server.broadcast).was_called_with("at_mentioned", {
          filePath = "/existing/dir/",
          lineStart = nil,
          lineEnd = nil,
        })
        assert.spy(mock_logger.debug).was_called()
      end)

      it("should handle broadcast failure", function()
        mock_server.broadcast = spy.new(function()
          return false
        end)

        command_handler({ args = "/existing/file.lua" })

        assert.spy(mock_logger.error).was_called()
        assert.spy(vim.notify).was_called()
      end)
    end)

    describe("path formatting", function()
      it("should handle file broadcasting correctly", function()
        -- Set up a file that exists
        vim.fn.filereadable = spy.new(function(path)
          return path == "/current/dir/src/test.lua" and 1 or 0
        end)

        command_handler({ args = "/current/dir/src/test.lua" })

        -- Just verify that broadcast was called with the expected structure
        assert.spy(mock_server.broadcast).was_called_with("at_mentioned", match.is_table())
        assert.spy(mock_logger.debug).was_called()
      end)

      it("should add trailing slash for directories", function()
        command_handler({ args = "/existing/dir" })

        assert.spy(mock_server.broadcast).was_called_with("at_mentioned", {
          filePath = "/existing/dir/",
          lineStart = nil,
          lineEnd = nil,
        })
      end)
    end)
  end)

  describe("integration with broadcast functions", function()
    it("should use the extracted broadcast_at_mention function", function()
      -- This test ensures that the command uses the centralized function
      -- rather than duplicating broadcast logic
      claudecode.setup({ auto_start = false })

      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCodeAdd" then
          command_handler = call.vals[2]
          break
        end
      end

      -- Mock the _format_path_for_at_mention function to verify it's called
      local original_format = claudecode._format_path_for_at_mention
      claudecode._format_path_for_at_mention = spy.new(function(path)
        return path, false
      end)

      command_handler({ args = "/existing/file.lua" })

      -- The command should call the format function and broadcast
      assert.spy(mock_server.broadcast).was_called()

      -- Restore original function
      claudecode._format_path_for_at_mention = original_format
    end)
  end)
end)
