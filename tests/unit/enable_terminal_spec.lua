require("tests.busted_setup")
require("tests.mocks.vim")

describe("enable_terminal configuration", function()
  -- Test config validation (no mocking needed)
  describe("config validation", function()
    it("should accept boolean true for enable_terminal", function()
      local config = require("claudecode.config")
      local valid_config = {
        port_range = { min = 10000, max = 65535 },
        auto_start = true,
        enable_terminal = true,
        log_level = "info",
        track_selection = true,
        visual_demotion_delay_ms = 50,
        connection_wait_delay = 200,
        connection_timeout = 10000,
        queue_timeout = 5000,
        diff_opts = {
          auto_close_on_accept = true,
          show_diff_stats = true,
          vertical_split = true,
          open_in_current_tab = true,
        },
      }

      local success = pcall(config.validate, valid_config)
      assert.is_true(success)
    end)

    it("should accept boolean false for enable_terminal", function()
      local config = require("claudecode.config")
      local valid_config = {
        port_range = { min = 10000, max = 65535 },
        auto_start = true,
        enable_terminal = false,
        log_level = "info",
        track_selection = true,
        visual_demotion_delay_ms = 50,
        connection_wait_delay = 200,
        connection_timeout = 10000,
        queue_timeout = 5000,
        diff_opts = {
          auto_close_on_accept = true,
          show_diff_stats = true,
          vertical_split = true,
          open_in_current_tab = true,
        },
      }

      local success = pcall(config.validate, valid_config)
      assert.is_true(success)
    end)

    it("should reject non-boolean values for enable_terminal", function()
      local config = require("claudecode.config")
      local invalid_config = {
        port_range = { min = 10000, max = 65535 },
        auto_start = true,
        enable_terminal = "true", -- Invalid: string instead of boolean
        log_level = "info",
        track_selection = true,
        visual_demotion_delay_ms = 50,
        connection_wait_delay = 200,
        connection_timeout = 10000,
        queue_timeout = 5000,
        diff_opts = {
          auto_close_on_accept = true,
          show_diff_stats = true,
          vertical_split = true,
          open_in_current_tab = true,
        },
      }

      local success, err = pcall(config.validate, invalid_config)
      assert.is_false(success)
      assert.is_not_nil(string.find(tostring(err), "enable_terminal must be a boolean"))
    end)

    it("should have enable_terminal = true as default", function()
      local config = require("claudecode.config")
      assert.is_true(config.defaults.enable_terminal)
    end)
  end)

  -- Test command registration based on config
  describe("command registration", function()
    local original_nvim_create_user_command

    before_each(function()
      -- Clear any loaded modules
      package.loaded["claudecode"] = nil
      package.loaded["claudecode.server.init"] = nil
      package.loaded["claudecode.terminal"] = nil

      -- Save original and set up spy
      original_nvim_create_user_command = vim.api.nvim_create_user_command
      spy.on(vim.api, "nvim_create_user_command")

      -- Mock minimal server functionality
      package.loaded["claudecode.server.init"] = {
        start = function()
          return true, 12345
        end,
        stop = function()
          return true
        end,
      }

      -- Mock lockfile
      package.loaded["claudecode.lockfile"] = {
        create = function()
          return true, nil, "test-token"
        end,
        remove = function()
          return true
        end,
        generate_auth_token = function()
          return "test-auth-token"
        end,
      }

      -- Mock other required modules minimally
      package.loaded["claudecode.selection"] = {
        enable = function() end,
        disable = function() end,
      }

      package.loaded["claudecode.diff"] = {
        setup = function() end,
      }

      package.loaded["claudecode.logger"] = {
        setup = function() end,
        info = function() end,
        warn = function() end,
        error = function() end,
        debug = function() end,
      }
    end)

    after_each(function()
      -- Restore original function
      vim.api.nvim_create_user_command = original_nvim_create_user_command
    end)

    it("should register terminal commands when enable_terminal is true", function()
      -- Mock terminal module
      package.loaded["claudecode.terminal"] = {
        setup = function() end,
        open = function() end,
        close = function() end,
        simple_toggle = function() end,
        focus_toggle = function() end,
        ensure_visible = function() end,
      }

      local claudecode = require("claudecode")
      claudecode.setup({
        auto_start = false,
        enable_terminal = true,
      })

      local registered_commands = {}
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        registered_commands[call.vals[1]] = true
      end

      assert.is_true(registered_commands["ClaudeCode"] ~= nil, "ClaudeCode command should be registered")
      assert.is_true(registered_commands["ClaudeCodeOpen"] ~= nil, "ClaudeCodeOpen command should be registered")
      assert.is_true(registered_commands["ClaudeCodeClose"] ~= nil, "ClaudeCodeClose command should be registered")
      assert.is_true(registered_commands["ClaudeCodeFocus"] ~= nil, "ClaudeCodeFocus command should be registered")
    end)

    it("should NOT register terminal commands when enable_terminal is false", function()
      -- Mock terminal module
      package.loaded["claudecode.terminal"] = {
        setup = function() end,
        open = function() end,
        close = function() end,
        simple_toggle = function() end,
        focus_toggle = function() end,
        ensure_visible = function() end,
      }

      local claudecode = require("claudecode")
      claudecode.setup({
        auto_start = false,
        enable_terminal = false,
      })

      local registered_commands = {}
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        registered_commands[call.vals[1]] = true
      end

      assert.is_nil(registered_commands["ClaudeCode"], "ClaudeCode command should NOT be registered")
      assert.is_nil(registered_commands["ClaudeCodeOpen"], "ClaudeCodeOpen command should NOT be registered")
      assert.is_nil(registered_commands["ClaudeCodeClose"], "ClaudeCodeClose command should NOT be registered")
      assert.is_nil(registered_commands["ClaudeCodeFocus"], "ClaudeCodeFocus command should NOT be registered")
    end)

    it("should NOT call terminal.setup when enable_terminal is false", function()
      local terminal_setup_called = false

      -- Mock terminal module with tracking
      package.loaded["claudecode.terminal"] = {
        setup = function()
          terminal_setup_called = true
        end,
        open = function() end,
        close = function() end,
        simple_toggle = function() end,
        focus_toggle = function() end,
        ensure_visible = function() end,
      }

      local claudecode = require("claudecode")
      claudecode.setup({
        auto_start = false,
        enable_terminal = false,
      })

      assert.is_false(terminal_setup_called, "terminal.setup should NOT be called when enable_terminal is false")
    end)

    it("should call terminal.setup when enable_terminal is true", function()
      local terminal_setup_called = false

      -- Mock terminal module with tracking
      package.loaded["claudecode.terminal"] = {
        setup = function()
          terminal_setup_called = true
        end,
        open = function() end,
        close = function() end,
        simple_toggle = function() end,
        focus_toggle = function() end,
        ensure_visible = function() end,
      }

      local claudecode = require("claudecode")
      claudecode.setup({
        auto_start = false,
        enable_terminal = true,
      })

      assert.is_true(terminal_setup_called, "terminal.setup should be called when enable_terminal is true")
    end)
  end)
end)
