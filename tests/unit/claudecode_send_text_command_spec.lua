-- Tests for the :ClaudeCodeSendText command (#197).
require("tests.busted_setup")
require("tests.mocks.vim")

describe("ClaudeCodeSendText command", function()
  local claudecode
  local mock_logger
  local mock_terminal
  local saved_require = _G.require

  local function setup_mocks()
    mock_logger = {
      setup = function() end,
      debug = spy.new(function() end),
      error = spy.new(function() end),
      warn = spy.new(function() end),
      info = spy.new(function() end),
    }

    mock_terminal = {
      setup = function() end,
      open = spy.new(function() end),
      close = spy.new(function() end),
      simple_toggle = spy.new(function() end),
      focus_toggle = spy.new(function() end),
      ensure_visible = spy.new(function() end),
      get_active_terminal_bufnr = function()
        return 1
      end,
      send_to_terminal = spy.new(function()
        return true
      end),
    }

    vim.fn.getcwd = function()
      return "/current/dir"
    end
    vim.api.nvim_create_user_command = spy.new(function() end)
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
        return { setup = function() end }
      elseif mod == "claudecode.terminal" then
        return mock_terminal
      elseif mod == "claudecode.visual_commands" then
        return {
          create_visual_command_wrapper = function(normal_handler)
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

    package.loaded["claudecode"] = nil
    package.loaded["claudecode.config"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.diff"] = nil
    package.loaded["claudecode.visual_commands"] = nil
    package.loaded["claudecode.terminal"] = nil

    claudecode = require("claudecode")
    claudecode.state.server = {
      broadcast = spy.new(function()
        return true
      end),
    }
    claudecode.state.port = 12345
  end)

  after_each(function()
    _G.require = saved_require
    package.loaded["claudecode"] = nil
  end)

  local function find_command(name)
    for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
      if call.vals[1] == name then
        return call.vals[2], call.vals[3]
      end
    end
  end

  it("registers ClaudeCodeSendText with nargs=+ and bang support", function()
    claudecode.setup({ auto_start = false })

    local handler, config = find_command("ClaudeCodeSendText")
    assert.is_function(handler)
    assert.is_equal("+", config.nargs)
    assert.is_true(config.bang)
    assert.is_string(config.desc)
  end)

  it("sends text and submits by default", function()
    claudecode.setup({ auto_start = false })
    local handler = find_command("ClaudeCodeSendText")

    handler({ args = "run the tests", bang = false })

    assert.spy(mock_terminal.send_to_terminal).was_called()
    local call = mock_terminal.send_to_terminal.calls[1]
    assert.is_equal("run the tests", call.vals[1])
    assert.is_true(call.vals[2].submit)
  end)

  it("inserts without submitting when bang is used", function()
    claudecode.setup({ auto_start = false })
    local handler = find_command("ClaudeCodeSendText")

    handler({ args = "draft text", bang = true })

    local call = mock_terminal.send_to_terminal.calls[1]
    assert.is_equal("draft text", call.vals[1])
    assert.is_false(call.vals[2].submit)
  end)

  it("warns and does not send when no text is provided", function()
    claudecode.setup({ auto_start = false })
    local handler = find_command("ClaudeCodeSendText")

    handler({ args = "", bang = false })

    assert.spy(mock_logger.warn).was_called()
    assert.spy(mock_terminal.send_to_terminal).was_not_called()
  end)
end)
