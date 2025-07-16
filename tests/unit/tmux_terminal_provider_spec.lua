-- luacheck: globals expect
require("tests.busted_setup")

describe("Tmux Terminal Provider", function()
  local tmux_provider
  local mock_vim
  local logger_debug_spy, logger_error_spy, logger_warn_spy

  local function setup_mocks()
    -- Mock vim global
    mock_vim = {
      notify = spy.new(function() end),
      log = { levels = { WARN = 2, ERROR = 1, INFO = 3, DEBUG = 4 } },
      env = { TMUX = "/private/tmp/tmux-501/default,97181,8" },
      fn = {
        system = spy.new(function(cmd)
          if cmd:match("tmux display%-message %-p") then
            return "100"
          elseif cmd:match("tmux list%-panes") then
            return "%1"
          elseif cmd:match("tmux split%-window.*display%-message") then
            return "%2"
          end
          return ""
        end),
      },
    }
    _G.vim = mock_vim

    -- Mock io.popen
    local original_io = _G.io
    _G.io = setmetatable({
      popen = spy.new(function(cmd)
        local mock_handle = {
          read = function(self, format)
            if cmd:match("tmux display%-message %-p '#{window_width}'") then
              return "100"
            elseif cmd:match("tmux list%-panes") then
              return "%2"
            elseif cmd:match("tmux split%-window.*display%-message") then
              return "%2"
            elseif cmd:match("tmux display%-message %-p '#{pane_active}'") then
              return "0"
            end
            return ""
          end,
          close = function() end,
        }
        return mock_handle
      end),
    }, {
      __index = function(_, key)
        return original_io[key]
      end,
    })

    -- Mock logger with spies
    logger_debug_spy = spy.new(function() end)
    logger_error_spy = spy.new(function() end)
    logger_warn_spy = spy.new(function() end)
    package.loaded["claudecode.logger"] = {
      debug = logger_debug_spy,
      warn = logger_warn_spy,
      error = logger_error_spy,
      info = function() end,
    }
  end

  before_each(function()
    -- Clear module cache
    package.loaded["claudecode.terminal.tmux"] = nil

    setup_mocks()
    tmux_provider = require("claudecode.terminal.tmux")
  end)

  describe("availability", function()
    it("should be available when in tmux session", function()
      expect(tmux_provider.is_available()).to_be_true()
    end)

    it("should not be available when not in tmux session", function()
      mock_vim.env.TMUX = nil
      -- Reload module to pick up new env
      package.loaded["claudecode.terminal.tmux"] = nil
      tmux_provider = require("claudecode.terminal.tmux")

      expect(tmux_provider.is_available()).to_be_false()
    end)
  end)

  describe("setup", function()
    it("should configure without errors in tmux session", function()
      tmux_provider.setup({ split_side = "left" })
      assert.spy(logger_debug_spy).was_called()
    end)

    it("should warn when not in tmux session", function()
      mock_vim.env.TMUX = nil
      package.loaded["claudecode.terminal.tmux"] = nil
      tmux_provider = require("claudecode.terminal.tmux")

      tmux_provider.setup({})
      assert.spy(logger_warn_spy).was_called()
    end)
  end)

  describe("pane management", function()
    it("should open new tmux pane with default config", function()
      local config = { split_side = "right", split_width_percentage = 0.5 }
      tmux_provider.open("claude --ide", {}, config)

      assert.spy(_G.io.popen).was_called()
      local call_args = _G.io.popen.calls[#_G.io.popen.calls].refs
      local command = call_args[1]
      assert.truthy(command:match("tmux split%-window %-h"))
    end)

    it("should open pane to the left when split_side is left", function()
      local config = { split_side = "left", split_width_percentage = 0.5 }
      tmux_provider.open("claude --ide", {}, config)

      assert.spy(_G.io.popen).was_called()
      local call_args = _G.io.popen.calls[#_G.io.popen.calls].refs
      local command = call_args[1]
      assert.truthy(command:match("tmux split%-window %-bh"))
    end)

    it("should include size parameter when split_width_percentage is valid", function()
      local config = { split_side = "right", split_width_percentage = 0.3 }
      tmux_provider.open("claude --ide", {}, config)

      assert.spy(_G.io.popen).was_called()
      local call_args = _G.io.popen.calls[#_G.io.popen.calls].refs
      local command = call_args[1]
      assert.truthy(command:match("%-l 30"))
    end)

    it("should not include size parameter when split_width_percentage is invalid", function()
      local config = { split_side = "right", split_width_percentage = 1.5 }
      tmux_provider.open("claude --ide", {}, config)

      assert.spy(_G.io.popen).was_called()
      local call_args = _G.io.popen.calls[#_G.io.popen.calls].refs
      local command = call_args[1]
      assert.falsy(command:match("%-l"))
    end)

    it("should error when trying to open pane outside tmux", function()
      mock_vim.env.TMUX = nil
      package.loaded["claudecode.terminal.tmux"] = nil
      tmux_provider = require("claudecode.terminal.tmux")

      tmux_provider.open("claude --ide", {}, {})
      assert.spy(logger_error_spy).was_called()
    end)

    it("should focus existing pane if already open", function()
      -- First call creates pane
      tmux_provider.open("claude --ide", {}, { split_side = "right" })

      -- Second call should focus existing
      tmux_provider.open("claude --ide", {}, { split_side = "right" })

      assert.spy(mock_vim.fn.system).was_called()
      local system_calls = mock_vim.fn.system.calls
      local focus_call = system_calls[#system_calls]
      assert.truthy(focus_call.refs[1]:match("tmux select%-pane"))
    end)
  end)

  describe("toggle operations", function()
    it("should open pane on simple_toggle when none exists", function()
      tmux_provider.simple_toggle("claude --ide", {}, { split_side = "right" })

      assert.spy(_G.io.popen).was_called()
      local call_args = _G.io.popen.calls[#_G.io.popen.calls].refs
      local command = call_args[1]
      assert.truthy(command:match("tmux split%-window"))
    end)

    it("should close pane on simple_toggle when pane exists", function()
      -- First open a pane
      tmux_provider.open("claude --ide", {}, { split_side = "right" })

      -- Then toggle should close it
      tmux_provider.simple_toggle("claude --ide", {}, { split_side = "right" })

      assert.spy(mock_vim.fn.system).was_called()
      local system_calls = mock_vim.fn.system.calls
      local close_call = system_calls[#system_calls]
      assert.truthy(close_call.refs[1]:match("tmux kill%-pane"))
    end)

    it("should handle focus_toggle correctly", function()
      tmux_provider.focus_toggle("claude --ide", {}, { split_side = "right" })

      assert.spy(_G.io.popen).was_called()
    end)
  end)

  describe("state management", function()
    it("should return nil for get_active_bufnr", function()
      expect(tmux_provider.get_active_bufnr()).to_be_nil()
    end)

    it("should provide test interface", function()
      local test_info = tmux_provider._get_terminal_for_test()
      assert.equal("table", type(test_info))
      assert.is_true(test_info.is_in_tmux)
    end)

    it("should clean up state when pane is closed externally", function()
      -- Open pane
      tmux_provider.open("claude --ide", {}, { split_side = "right" })

      -- Mock pane no longer existing
      _G.io.popen = spy.new(function(cmd)
        local mock_handle = {
          read = function()
            return ""
          end, -- Empty result means pane doesn't exist
          close = function() end,
        }
        return mock_handle
      end)

      -- Try to close - should handle gracefully
      tmux_provider.close()
      assert.spy(logger_debug_spy).was_called()
    end)
  end)
end)
