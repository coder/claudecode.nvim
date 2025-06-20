require("tests.busted_setup")
require("tests.mocks.vim")

describe("claudecode.init", function()
  ---@class AutocmdOptions
  ---@field group string|number|nil
  ---@field pattern string|string[]|nil
  ---@field buffer number|nil
  ---@field desc string|nil
  ---@field callback function|nil
  ---@field once boolean|nil
  ---@field nested boolean|nil

  local saved_vim_api = vim.api
  local saved_vim_deepcopy = vim.deepcopy
  local saved_vim_tbl_deep_extend = vim.tbl_deep_extend
  local saved_vim_notify = vim.notify
  local saved_vim_fn = vim.fn
  local saved_vim_log = vim.log
  local saved_require = _G.require

  local mock_server = {
    start = function()
      return true, 12345
    end,
    ---@type SpyableFunction
    stop = function()
      return true
    end,
  }

  local mock_lockfile = {
    create = function()
      return true, "/mock/path", "mock-auth-token-12345"
    end,
    ---@type SpyableFunction
    remove = function()
      return true
    end,
    generate_auth_token = function()
      return "mock-auth-token-12345"
    end,
  }

  local mock_selection = {
    enable = function() end,
    disable = function() end,
  }

  local SpyObject = {}
  function SpyObject.new(fn)
    local spy_obj = {
      _original = fn,
      calls = {},
    }

    function spy_obj.spy()
      return {
        was_called = function(n)
          assert(#spy_obj.calls == n, "Expected " .. n .. " calls, got " .. #spy_obj.calls)
          return true
        end,
        was_not_called = function()
          assert(#spy_obj.calls == 0, "Expected 0 calls, got " .. #spy_obj.calls)
          return true
        end,
        was_called_with = function(...)
          -- args is unused but keeping the parameter for clarity, as the function signature might be relevant for future tests
          assert(#spy_obj.calls > 0, "Function was never called")
          return true
        end,
      }
    end

    return setmetatable(spy_obj, {
      __call = function(self, ...)
        table.insert(self.calls, { vals = { ... } })
        if self._original then
          return self._original(...)
        end
      end,
    })
  end

  local match = {
    is_table = function()
      return { is_table = true }
    end,
  }

  before_each(function()
    vim.api = {
      nvim_create_autocmd = SpyObject.new(function() end),
      nvim_create_augroup = SpyObject.new(function()
        return 1
      end),
      nvim_create_user_command = SpyObject.new(function() end),
      nvim_echo = SpyObject.new(function() end),
    }

    vim.deepcopy = function(t)
      return t
    end

    vim.tbl_deep_extend = function(_, default, override)
      local result = {}
      for k, v in pairs(default) do
        result[k] = v
      end
      for k, v in pairs(override) do
        result[k] = v
      end
      return result
    end

    vim.notify = spy.new(function() end)

    vim.fn = { ---@type vim_fn_table
      getpid = function()
        return 123
      end,
      expand = function()
        return "/mock/path"
      end,
      mode = function()
        return "n"
      end,
      delete = function(_, _)
        return 0
      end,
      filereadable = function(_)
        return 1
      end,
      fnamemodify = function(fname, _)
        return fname
      end,
      getcwd = function()
        return "/mock/cwd"
      end,
      mkdir = function(_, _, _)
        return 1
      end,
      buflisted = function(_)
        return 1
      end,
      bufname = function(_)
        return "mockbuffer"
      end,
      bufnr = function(_)
        return 1
      end,
      win_getid = function()
        return 1
      end,
      win_gotoid = function(_)
        return true
      end,
      line = function(_)
        return 1
      end,
      col = function(_)
        return 1
      end,
      virtcol = function(_)
        return 1
      end,
      getpos = function(_)
        return { 0, 1, 1, 0 }
      end,
      setpos = function(_, _)
        return true
      end,
      tempname = function()
        return "/tmp/mocktemp"
      end,
      globpath = function(_, _)
        return ""
      end,
      stdpath = function(_)
        return "/mock/stdpath"
      end,
      json_encode = function(_)
        return "{}"
      end,
      json_decode = function(_)
        return {}
      end,
      termopen = function(_, _)
        return 0
      end,
    }

    vim.log = {
      levels = {
        NONE = 0,
        INFO = 2,
        WARN = 3,
        ERROR = 4,
        DEBUG = 5,
        TRACE = 6,
      },
    }

    mock_server.stop = SpyObject.new(mock_server.stop)
    mock_lockfile.remove = SpyObject.new(mock_lockfile.remove)

    _G.require = function(mod)
      if mod == "claudecode.server.init" then
        return mock_server
      elseif mod == "claudecode.lockfile" then
        return mock_lockfile
      elseif mod == "claudecode.selection" then
        return mock_selection
      else
        return saved_require(mod)
      end
    end

    _G.match = match
  end)

  after_each(function()
    vim.api = saved_vim_api
    vim.deepcopy = saved_vim_deepcopy
    vim.tbl_deep_extend = saved_vim_tbl_deep_extend
    vim.notify = saved_vim_notify
    vim.fn = saved_vim_fn
    vim.log = saved_vim_log
    _G.require = saved_require
  end)

  describe("setup", function()
    it("should register VimLeavePre autocmd for auto-shutdown", function()
      local claudecode = require("claudecode")
      claudecode.setup()

      assert(#vim.api.nvim_create_augroup.calls > 0, "nvim_create_augroup was not called")
      assert(#vim.api.nvim_create_autocmd.calls > 0, "nvim_create_autocmd was not called")

      assert(vim.api.nvim_create_autocmd.calls[1].vals[1] == "VimLeavePre", "Expected VimLeavePre event")
    end)
  end)

  describe("auto-shutdown", function()
    it("should stop the server and remove lockfile when Neovim exits", function()
      local claudecode = require("claudecode")
      claudecode.setup()
      claudecode.start()

      local callback_fn = nil
      for _, call in ipairs(vim.api.nvim_create_autocmd.calls) do
        if call.vals[1] == "VimLeavePre" then
          -- The mock for nvim_create_augroup returns 1, and this is passed as the group.
          if call.vals[2] and call.vals[2].group == 1 then
            callback_fn = call.vals[2].callback
            break
          end
        end
      end
      assert(callback_fn, "Callback for VimLeavePre with ClaudeCodeShutdown group not found")

      mock_server.stop.calls = {}
      mock_lockfile.remove.calls = {}

      if callback_fn then
        callback_fn()
      end

      assert(#mock_server.stop.calls > 0, "Server stop was not called")
      assert(#mock_lockfile.remove.calls > 0, "Lockfile remove was not called")
    end)

    it("should do nothing if the server is not running", function()
      local claudecode = require("claudecode")
      claudecode.setup({ auto_start = false })

      local opts = vim.api.nvim_create_autocmd.calls[1].vals[2]
      local callback_fn = opts.callback

      mock_server.stop.calls = {}
      mock_lockfile.remove.calls = {}

      if callback_fn then
        callback_fn()
      end

      assert(#mock_server.stop.calls == 0, "Server stop was called unexpectedly")
      assert(#mock_lockfile.remove.calls == 0, "Lockfile remove was called unexpectedly")
    end)
  end)

  describe("ClaudeCode command with arguments", function()
    local mock_terminal

    before_each(function()
      mock_terminal = {
        toggle = spy.new(function() end),
        simple_toggle = spy.new(function() end),
        focus_toggle = spy.new(function() end),
        open = spy.new(function() end),
        close = spy.new(function() end),
        setup = spy.new(function() end),
        ensure_visible = spy.new(function() end),
      }

      local original_require = _G.require
      _G.require = function(mod)
        if mod == "claudecode.terminal" then
          return mock_terminal
        elseif mod == "claudecode.server.init" then
          return mock_server
        elseif mod == "claudecode.lockfile" then
          return mock_lockfile
        elseif mod == "claudecode.selection" then
          return mock_selection
        else
          return original_require(mod)
        end
      end
    end)

    it("should register ClaudeCode command with nargs='*'", function()
      local claudecode = require("claudecode")
      claudecode.setup({ auto_start = false })

      local command_found = false
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCode" then
          command_found = true
          local config = call.vals[3]
          assert.is_equal("*", config.nargs)
          assert.is_true(
            string.find(config.desc, "optional arguments") ~= nil,
            "Description should mention optional arguments"
          )
          break
        end
      end
      assert.is_true(command_found, "ClaudeCode command was not registered")
    end)

    it("should register ClaudeCodeOpen command with nargs='*'", function()
      local claudecode = require("claudecode")
      claudecode.setup({ auto_start = false })

      local command_found = false
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCodeOpen" then
          command_found = true
          local config = call.vals[3]
          assert.is_equal("*", config.nargs)
          assert.is_true(
            string.find(config.desc, "optional arguments") ~= nil,
            "Description should mention optional arguments"
          )
          break
        end
      end
      assert.is_true(command_found, "ClaudeCodeOpen command was not registered")
    end)

    it("should parse and pass arguments to terminal.toggle for ClaudeCode command", function()
      local claudecode = require("claudecode")
      claudecode.setup({ auto_start = false })

      -- Find and call the ClaudeCode command handler
      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCode" then
          command_handler = call.vals[2]
          break
        end
      end

      assert.is_function(command_handler, "Command handler should be a function")

      command_handler({ args = "--resume --verbose" })

      assert(#mock_terminal.simple_toggle.calls > 0, "terminal.simple_toggle was not called")
      local call_args = mock_terminal.simple_toggle.calls[1].vals
      assert.is_table(call_args[1], "First argument should be a table")
      assert.is_equal("--resume --verbose", call_args[2], "Second argument should be the command args")
    end)

    it("should parse and pass arguments to terminal.open for ClaudeCodeOpen command", function()
      local claudecode = require("claudecode")
      claudecode.setup({ auto_start = false })

      -- Find and call the ClaudeCodeOpen command handler
      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCodeOpen" then
          command_handler = call.vals[2]
          break
        end
      end

      assert.is_function(command_handler, "Command handler should be a function")

      command_handler({ args = "--flag1 --flag2" })

      assert(#mock_terminal.open.calls > 0, "terminal.open was not called")
      local call_args = mock_terminal.open.calls[1].vals
      assert.is_table(call_args[1], "First argument should be a table")
      assert.is_equal("--flag1 --flag2", call_args[2], "Second argument should be the command args")
    end)

    it("should handle empty arguments gracefully", function()
      local claudecode = require("claudecode")
      claudecode.setup({ auto_start = false })

      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCode" then
          command_handler = call.vals[2]
          break
        end
      end

      command_handler({ args = "" })

      assert(#mock_terminal.simple_toggle.calls > 0, "terminal.simple_toggle was not called")
      local call_args = mock_terminal.simple_toggle.calls[1].vals
      assert.is_nil(call_args[2], "Second argument should be nil for empty args")
    end)

    it("should handle nil arguments gracefully", function()
      local claudecode = require("claudecode")
      claudecode.setup({ auto_start = false })

      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCode" then
          command_handler = call.vals[2]
          break
        end
      end

      command_handler({ args = nil })

      assert(#mock_terminal.simple_toggle.calls > 0, "terminal.simple_toggle was not called")
      local call_args = mock_terminal.simple_toggle.calls[1].vals
      assert.is_nil(call_args[2], "Second argument should be nil when args is nil")
    end)

    it("should maintain backward compatibility when no arguments provided", function()
      local claudecode = require("claudecode")
      claudecode.setup({ auto_start = false })

      local command_handler
      for _, call in ipairs(vim.api.nvim_create_user_command.calls) do
        if call.vals[1] == "ClaudeCode" then
          command_handler = call.vals[2]
          break
        end
      end

      command_handler({})

      assert(#mock_terminal.simple_toggle.calls > 0, "terminal.simple_toggle was not called")
      local call_args = mock_terminal.simple_toggle.calls[1].vals
      assert.is_nil(call_args[2], "Second argument should be nil when no args provided")
    end)
  end)
end)
