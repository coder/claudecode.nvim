-- luacheck: globals expect
require("tests.busted_setup")

describe("External Terminal Provider", function()
  local external_provider
  local mock_vim
  local logger_debug_spy

  local function setup_mocks()
    -- Mock vim global
    mock_vim = {
      notify = spy.new(function() end),
      log = { levels = { WARN = 2, ERROR = 1, INFO = 3, DEBUG = 4 } },
    }
    _G.vim = mock_vim

    -- Mock logger with spy
    logger_debug_spy = spy.new(function() end)
    package.loaded["claudecode.logger"] = {
      debug = logger_debug_spy,
      warn = function() end,
      error = function() end,
      info = function() end,
    }
  end

  before_each(function()
    -- Clear module cache
    package.loaded["claudecode.terminal.external"] = nil

    setup_mocks()
    external_provider = require("claudecode.terminal.external")
  end)

  describe("basic functionality", function()
    it("should be available", function()
      expect(external_provider.is_available()).to_be_true()
    end)

    it("should return nil for active buffer", function()
      expect(external_provider.get_active_bufnr()).to_be_nil()
    end)

    it("should return nil for test terminal", function()
      expect(external_provider._get_terminal_for_test()).to_be_nil()
    end)
  end)

  describe("no-op functions", function()
    it("should do nothing on setup", function()
      external_provider.setup({ some_config = true })
      -- Should not error and should log debug message
      assert.spy(logger_debug_spy).was_called()
    end)

    it("should do nothing on open", function()
      external_provider.open("claude --ide", { ENV = "test" }, { split_side = "right" }, true)
      -- Should not error and should log debug message
      assert.spy(logger_debug_spy).was_called()
    end)

    it("should do nothing on close", function()
      external_provider.close()
      -- Should not error and should log debug message
      assert.spy(logger_debug_spy).was_called()
    end)

    it("should do nothing on simple_toggle", function()
      external_provider.simple_toggle("claude", {}, {})
      -- Should not error and should log debug message
      assert.spy(logger_debug_spy).was_called()
    end)

    it("should do nothing on focus_toggle", function()
      external_provider.focus_toggle("claude", {}, {})
      -- Should not error and should log debug message
      assert.spy(logger_debug_spy).was_called()
    end)

    it("should do nothing on toggle", function()
      external_provider.toggle("claude", {}, {})
      -- Should not error and should log debug message
      assert.spy(logger_debug_spy).was_called()
    end)
  end)
end)
