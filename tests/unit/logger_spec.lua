-- luacheck: globals expect
require("tests.busted_setup")

describe("Logger", function()
  local logger
  local original_vim_schedule
  local original_vim_notify
  local original_nvim_echo
  local scheduled_calls = {}
  local notify_calls = {}
  local echo_calls = {}

  local function setup()
    package.loaded["claudecode.logger"] = nil

    -- Mock vim.schedule to track calls
    original_vim_schedule = vim.schedule
    vim.schedule = function(fn)
      table.insert(scheduled_calls, fn)
      -- Immediately execute the function for testing
      fn()
    end

    -- Mock vim.notify to track calls
    original_vim_notify = vim.notify
    vim.notify = function(msg, level, opts)
      table.insert(notify_calls, { msg = msg, level = level, opts = opts })
    end

    -- Mock nvim_echo to track calls
    original_nvim_echo = vim.api.nvim_echo
    vim.api.nvim_echo = function(chunks, history, opts)
      table.insert(echo_calls, { chunks = chunks, history = history, opts = opts })
    end

    logger = require("claudecode.logger")

    -- Set log level to TRACE to enable all logging levels for testing
    logger.setup({ log_level = "trace" })
  end

  local function teardown()
    vim.schedule = original_vim_schedule
    vim.notify = original_vim_notify
    vim.api.nvim_echo = original_nvim_echo
    scheduled_calls = {}
    notify_calls = {}
    echo_calls = {}
  end

  before_each(function()
    setup()
  end)

  after_each(function()
    teardown()
  end)

  describe("error logging", function()
    it("should wrap error calls in vim.schedule", function()
      logger.error("test", "error message")

      -- Should have made one scheduled call
      expect(#scheduled_calls).to_be(1)

      -- Should have called vim.notify with error level
      expect(#notify_calls).to_be(1)
      expect(notify_calls[1].level).to_be(vim.log.levels.ERROR)
      assert_contains(notify_calls[1].msg, "error message")
    end)

    it("should handle error calls without component", function()
      logger.error("error message")

      expect(#scheduled_calls).to_be(1)
      expect(#notify_calls).to_be(1)
      assert_contains(notify_calls[1].msg, "error message")
    end)
  end)

  describe("warn logging", function()
    it("should wrap warn calls in vim.schedule", function()
      logger.warn("test", "warning message")

      -- Should have made one scheduled call
      expect(#scheduled_calls).to_be(1)

      -- Should have called vim.notify with warn level
      expect(#notify_calls).to_be(1)
      expect(notify_calls[1].level).to_be(vim.log.levels.WARN)
      assert_contains(notify_calls[1].msg, "warning message")
    end)

    it("should handle warn calls without component", function()
      logger.warn("warning message")

      expect(#scheduled_calls).to_be(1)
      expect(#notify_calls).to_be(1)
      assert_contains(notify_calls[1].msg, "warning message")
    end)
  end)

  describe("info logging", function()
    it("should wrap info calls in vim.schedule", function()
      logger.info("test", "info message")

      -- Should have made one scheduled call
      expect(#scheduled_calls).to_be(1)

      -- Should have called nvim_echo instead of notify
      expect(#echo_calls).to_be(1)
      expect(#notify_calls).to_be(0)
      assert_contains(echo_calls[1].chunks[1][1], "info message")
    end)
  end)

  describe("debug logging", function()
    it("should wrap debug calls in vim.schedule", function()
      logger.debug("test", "debug message")

      -- Should have made one scheduled call
      expect(#scheduled_calls).to_be(1)

      -- Should have called nvim_echo instead of notify
      expect(#echo_calls).to_be(1)
      expect(#notify_calls).to_be(0)
      assert_contains(echo_calls[1].chunks[1][1], "debug message")
    end)
  end)

  describe("trace logging", function()
    it("should wrap trace calls in vim.schedule", function()
      logger.trace("test", "trace message")

      -- Should have made one scheduled call
      expect(#scheduled_calls).to_be(1)

      -- Should have called nvim_echo instead of notify
      expect(#echo_calls).to_be(1)
      expect(#notify_calls).to_be(0)
      assert_contains(echo_calls[1].chunks[1][1], "trace message")
    end)
  end)

  -- The server logs from libuv callbacks while the user types. A line wider than the command line (v:echospace
  -- cells) stops Neovim at "Press ENTER" until the user presses a key.
  describe("one_line", function()
    local original_echospace

    before_each(function()
      original_echospace = vim.v.echospace
      vim.v.echospace = 50
      logger.setup({ log_level = "info" })
    end)

    after_each(function()
      vim.v.echospace = original_echospace
    end)

    it("drops the component and level, then cuts, an error wider than the command line", function()
      logger.one_line("error", "server", "Accept error: EMFILE: too many open files")

      expect(#notify_calls).to_be(1)
      expect(notify_calls[1].level).to_be(vim.log.levels.ERROR)
      expect(notify_calls[1].msg).to_be("[ClaudeCode] Accept error: EMFILE: too many ope...")
    end)

    it("drops only the component and level when the line then fits", function()
      logger.one_line("warn", "client", "Rejected client_1: Invalid token")

      expect(notify_calls[1].msg).to_be("[ClaudeCode] Rejected client_1: Invalid token")
    end)

    it("cuts an info line, which goes to the message history", function()
      logger.one_line("info", "server", "Closed client_7: no reply for 61s, and more text")

      expect(#echo_calls).to_be(1)
      expect(echo_calls[1].history).to_be_true()
      expect(echo_calls[1].chunks[1][1]).to_be("[ClaudeCode] Closed client_7: no reply for 61s,...")
    end)

    it("joins the lines of a warning into one", function()
      vim.v.echospace = 80
      logger.one_line("warn", "client", "Rejected client_1:\r\n  Invalid token")

      expect(notify_calls[1].level).to_be(vim.log.levels.WARN)
      expect(notify_calls[1].msg).to_be("[ClaudeCode] [client] [WARN] Rejected client_1: Invalid token")
    end)

    it("keeps a line that fits, measured in cells and not bytes", function()
      local text = string.rep("\195\169", 20) -- 20 cells, 40 bytes

      logger.one_line("info", "server", text)

      expect(echo_calls[1].chunks[1][1]).to_be("[ClaudeCode] [server] [INFO] " .. text)
    end)

    it("drops the plugin name too when it would take half of a narrow command line", function()
      vim.v.echospace = 20

      logger.one_line("error", "server", "Accept error: EMFILE: too many open files")

      expect(notify_calls[1].msg).to_be("Accept error: EMF...")
    end)

    it("cuts without an ellipsis when the command line is narrower than one", function()
      vim.v.echospace = 2

      logger.one_line("error", "server", "Accept error: EMFILE: too many open files")

      expect(notify_calls[1].msg).to_be("Ac")
    end)

    it("shows the whole line at log_level debug", function()
      logger.setup({ log_level = "debug" })

      logger.one_line("error", "server", "Accept error: EMFILE: too many open files")

      expect(notify_calls[1].msg).to_be("[ClaudeCode] [server] [ERROR] Accept error: EMFILE: too many open files")
    end)

    it("shows nothing below the log level", function()
      logger.setup({ log_level = "warn" })

      logger.one_line("info", "server", "Closed client_7: no reply for 61s")

      expect(#echo_calls).to_be(0)
    end)
  end)

  describe("fast event context safety", function()
    it("should not call vim API functions directly", function()
      -- Simulate a fast event context by removing the mocked functions
      -- and ensuring no direct calls are made
      local direct_notify_called = false
      local direct_echo_called = false

      vim.notify = function()
        direct_notify_called = true
      end

      vim.api.nvim_echo = function()
        direct_echo_called = true
      end

      vim.schedule = function(fn)
        -- Don't execute the function, just verify it was scheduled
        table.insert(scheduled_calls, fn)
      end

      logger.error("test", "error in fast context")
      logger.warn("test", "warn in fast context")
      logger.info("test", "info in fast context")

      -- All should be scheduled, none should be called directly
      expect(#scheduled_calls).to_be(3)
      expect(direct_notify_called).to_be_false()
      expect(direct_echo_called).to_be_false()
    end)
  end)
end)
