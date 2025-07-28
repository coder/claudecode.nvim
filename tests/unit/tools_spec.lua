-- luacheck: globals expect
require("tests.busted_setup")

describe("Tools Module", function()
  local tools
  local mock_vim
  local spy -- For spying on functions

  local function setup()
    package.loaded["claudecode.tools.init"] = nil
    package.loaded["claudecode.diff"] = nil
    package.loaded["luassert.spy"] = nil -- Ensure spy is fresh

    spy = require("luassert.spy")

    mock_vim = {
      fn = {
        expand = function(path)
          return path
        end,
        filereadable = function()
          return 1
        end,
        fnameescape = function(path)
          return path
        end,
        bufnr = function()
          return 1
        end,
        buflisted = function()
          return 1
        end,
        getcwd = function()
          return "/test/workspace"
        end,
        fnamemodify = function(path, modifier)
          if modifier == ":t" then
            return "workspace"
          end
          return path
        end,
      },
      cmd = function() end,
      api = {
        nvim_list_bufs = function()
          return { 1, 2 }
        end,
        nvim_buf_is_loaded = function()
          return true
        end,
        nvim_buf_get_name = function(bufnr)
          if bufnr == 1 then
            return "/test/file1.lua"
          end
          if bufnr == 2 then
            return "/test/file2.lua"
          end
          return ""
        end,
        nvim_buf_get_option = function()
          return false
        end,
        nvim_buf_call = function(bufnr, fn_to_call) -- Renamed to avoid conflict
          fn_to_call()
        end,
        nvim_buf_delete = function() end,
      },
      lsp = {},
      diagnostic = {
        get = function()
          return {
            {
              bufnr = 1,
              lnum = 10,
              col = 5,
              severity = 1,
              message = "Test error",
              source = "test",
            },
          }
        end,
      },
      json = {
        encode = function(obj)
          return vim.inspect(obj) -- Use the real vim.inspect if available, or our mock
        end,
      },
      notify = function() end,
      log = { -- Add mock for vim.log
        levels = {
          TRACE = 0,
          DEBUG = 1,
          ERROR = 2,
          WARN = 3, -- Add other common levels for completeness if needed
          INFO = 4,
        },
      },
      inspect = function(obj) -- Keep the mock inspect for controlled output
        if type(obj) == "string" then
          return '"' .. obj .. '"'
        elseif type(obj) == "table" then
          local items = {}
          for k, v in pairs(obj) do
            table.insert(items, tostring(k) .. ": " .. mock_vim.inspect(v))
          end
          return "{" .. table.concat(items, ", ") .. "}"
        else
          return tostring(obj)
        end
      end,
    }

    _G.vim = mock_vim

    tools = require("claudecode.tools.init")
    -- Ensure tools are registered for testing handle_invoke
    tools.register_all()
  end

  local function teardown()
    _G.vim = nil
    package.loaded["luassert.spy"] = nil
    spy = nil
  end

  local function contains(str, pattern)
    if type(str) ~= "string" or type(pattern) ~= "string" then
      return false
    end
    return str:find(pattern, 1, true) ~= nil
  end

  before_each(function()
    setup()
  end)

  after_each(function()
    teardown()
  end)

  describe("Tool Registration", function()
    it("should register all tools", function()
      -- tools.register_all() is called in setup

      expect(tools.tools).to_be_table()
      expect(tools.tools.openFile).to_be_table()
      expect(tools.tools.openFile.handler).to_be_function()
      expect(tools.tools.getDiagnostics).to_be_table()
      expect(tools.tools.getDiagnostics.handler).to_be_function()
      expect(tools.tools.getOpenEditors).to_be_table()
      expect(tools.tools.getOpenEditors.handler).to_be_function()
      expect(tools.tools.openDiff).to_be_table()
      expect(tools.tools.openDiff.handler).to_be_function()
      -- Add more checks for other registered tools as needed
    end)

    it("should allow registering custom tools", function()
      local custom_tool_handler = spy.new(function()
        return "custom result"
      end)
      local custom_tool_module = {
        name = "customTool",
        schema = nil,
        handler = custom_tool_handler,
      }
      tools.register(custom_tool_module)

      expect(tools.tools.customTool.handler).to_be(custom_tool_handler)
    end)
  end)

  describe("Tool Invocation Handler (handle_invoke)", function()
    it("should handle valid tool invocation and return result (e.g., getOpenEditors)", function()
      -- The 'tools' module and its handlers were loaded in setup() when _G.vim was 'mock_vim'.
      -- So, we need to modify the spies on the 'mock_vim' instance directly.
      mock_vim.api.nvim_list_bufs = spy.new(function()
        return { 1 }
      end)
      mock_vim.api.nvim_buf_is_loaded = spy.new(function(b)
        return b == 1
      end)
      mock_vim.fn.buflisted = spy.new(function(b) -- Ensure this is on mock_vim.fn
        if b == 1 then
          return 1
        else
          return 0
        end -- Must return number 0 or 1
      end)
      mock_vim.api.nvim_buf_get_name = spy.new(function(b)
        if b == 1 then
          return "/test/file.lua"
        else
          return ""
        end
      end)
      mock_vim.api.nvim_buf_get_option = spy.new(function(b, opt)
        if b == 1 and opt == "modified" then
          return false
        elseif b == 1 and opt == "filetype" then
          return "lua"
        else
          return nil
        end
      end)
      mock_vim.api.nvim_get_current_buf = spy.new(function()
        return 1
      end)
      mock_vim.api.nvim_get_current_tabpage = spy.new(function()
        return 1
      end)
      mock_vim.api.nvim_buf_line_count = spy.new(function(b)
        if b == 1 then
          return 100
        end
        return 0
      end)
      mock_vim.fn.fnamemodify = spy.new(function(path, modifier)
        if modifier == ":t" then
          return path:match("[^/]+$") or path
        end
        return path
      end)
      mock_vim.json.encode = spy.new(function(data, opts)
        return require("tests.busted_setup").json_encode(data)
      end)

      -- Mock selection module to prevent errors
      package.loaded["claudecode.selection"] = {
        get_latest_selection = function()
          return nil
        end,
      }

      -- Re-register the specific tool to ensure its handler picks up the new spies
      package.loaded["claudecode.tools.get_open_editors"] = nil -- Clear cache for the sub-tool
      tools.register(require("claudecode.tools.get_open_editors"))

      local params = {
        name = "getOpenEditors",
        arguments = {},
      }
      local result_obj = tools.handle_invoke(nil, params)

      expect(result_obj.result).to_be_table() -- "Expected .result to be a table"
      expect(result_obj.result.content).to_be_table() -- "Expected .result.content to be a table"
      expect(result_obj.result.content[1]).to_be_table()
      expect(result_obj.result.content[1].type).to_be("text")

      local parsed_result = require("tests.busted_setup").json_decode(result_obj.result.content[1].text)
      expect(parsed_result.tabs).to_be_table()
      expect(#parsed_result.tabs).to_be(1)
      expect(parsed_result.tabs[1].uri).to_be("file:///test/file.lua")
      expect(parsed_result.tabs[1].label).to_be("file.lua")
      expect(result_obj.error).to_be_nil() -- "Expected .error to be nil for successful call"

      expect(mock_vim.api.nvim_list_bufs.calls).to_be_table() -- Check if .calls table exists
      expect(#mock_vim.api.nvim_list_bufs.calls > 0).to_be_true() -- Then, check if called
      expect(mock_vim.api.nvim_buf_is_loaded.calls[1].vals[1]).to_be(1) -- Check first arg of first call
      expect(mock_vim.fn.buflisted.calls[1].vals[1]).to_be(1) -- Check first arg of first call
      expect(mock_vim.api.nvim_buf_get_name.calls[1].vals[1]).to_be(1) -- Check first arg of first call
      expect(mock_vim.api.nvim_buf_get_option.calls[1].vals[1]).to_be(1) -- Check first arg of first call
      -- Check that both 'filetype' and 'modified' options were requested, regardless of order
      local get_option_calls = mock_vim.api.nvim_buf_get_option.calls
      local options_requested = {}
      for i = 1, #get_option_calls do
        table.insert(options_requested, get_option_calls[i].vals[2])
      end

      local found_filetype = false
      local found_modified = false
      for _, v in ipairs(options_requested) do
        if v == "filetype" then
          found_filetype = true
        end
        if v == "modified" then
          found_modified = true
        end
      end

      expect(found_filetype).to_be_true("Expected 'filetype' option to be requested")
      expect(found_modified).to_be_true("Expected 'modified' option to be requested")

      -- Clean up selection module mock
      package.loaded["claudecode.selection"] = nil
    end)

    it("should handle unknown tool invocation with JSON-RPC error", function()
      local params = {
        name = "unknownTool",
        arguments = {},
      }
      local result_obj = tools.handle_invoke(nil, params)

      expect(result_obj.error).to_be_table()
      expect(result_obj.error.code).to_be(-32601) -- Method not found
      expect(contains(result_obj.error.message, "Tool not found: unknownTool")).to_be_true()
      expect(result_obj.result).to_be_nil()
    end)

    it("should handle tool execution errors (structured error from handler) with JSON-RPC error", function()
      local erroring_tool_handler = spy.new(function()
        error({ code = -32001, message = "Specific tool error from handler", data = { detail = "some detail" } })
      end)
      tools.register({
        name = "errorToolStructured",
        schema = nil,
        handler = erroring_tool_handler,
      })

      local params = { name = "errorToolStructured", arguments = {} }
      local result_obj = tools.handle_invoke(nil, params)

      expect(result_obj.error).to_be_table()
      expect(result_obj.error.code).to_be(-32001)
      expect(result_obj.error.message).to_be("Specific tool error from handler")
      expect(result_obj.error.data).to_be_table()
      expect(result_obj.error.data.detail).to_be("some detail")
      expect(result_obj.result).to_be_nil()
      expect(erroring_tool_handler.calls).to_be_table()
      expect(#erroring_tool_handler.calls > 0).to_be_true()
    end)

    it("should handle tool execution errors (simple string error from handler) with JSON-RPC error", function()
      local erroring_tool_handler_string = spy.new(function()
        error("Simple string error from tool handler")
      end)
      tools.register({
        name = "errorToolString",
        schema = nil,
        handler = erroring_tool_handler_string,
      })

      local params = { name = "errorToolString", arguments = {} }
      local result_obj = tools.handle_invoke(nil, params)

      expect(result_obj.error).to_be_table()
      expect(result_obj.error.code).to_be(-32000) -- Default server error for unhandled/string errors
      assert_contains(result_obj.error.message, "Simple string error from tool handler") -- Message includes traceback
      assert_contains(result_obj.error.data, "Simple string error from tool handler") -- Original error string in data
      expect(result_obj.result).to_be_nil()
      expect(erroring_tool_handler_string.calls).to_be_table()
      expect(#erroring_tool_handler_string.calls > 0).to_be_true()
    end)

    it("should handle tool execution errors (pcall/xpcall style error from handler) with JSON-RPC error", function()
      local erroring_tool_handler_pcall = spy.new(function()
        -- Simulate a tool that returns an error status and message, like from pcall
        return false, "Pcall-style error message"
      end)
      tools.register({
        name = "errorToolPcallStyle",
        schema = nil,
        handler = erroring_tool_handler_pcall,
      })

      local params = { name = "errorToolPcallStyle", arguments = {} }
      local result_obj = tools.handle_invoke(nil, params)

      expect(result_obj.error).to_be_table()
      expect(result_obj.error.code).to_be(-32000) -- Default server error
      expect(result_obj.error.message).to_be("Pcall-style error message") -- This should be exact as it's not passed through Lua's error()
      expect(result_obj.error.data).not_to_be_nil() -- "error.data should not be nil for pcall-style string errors"
      expect(type(result_obj.error.data)).to_be("string") -- Check type explicitly
      assert_contains(result_obj.error.data, "Pcall-style error message")
      expect(result_obj.result).to_be_nil()
      expect(erroring_tool_handler_pcall.calls).to_be_table()
      expect(#erroring_tool_handler_pcall.calls > 0).to_be_true()
    end)
  end)

  -- All individual tool describe blocks (e.g., "Open File Tool", "Get Diagnostics Tool", etc.)
  -- were removed from this file as of the refactoring on 2025-05-26.
  -- Their functionality is now tested in their respective spec files
  -- under tests/unit/tools/impl/.
  -- This file now focuses on the tool registration and the generic handle_invoke logic.

  teardown()
end)
