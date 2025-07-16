-- luacheck: globals expect
require("tests.busted_setup")

describe("MCP Tools Integration", function()
  -- Clear module cache at the start of the describe block
  package.loaded["claudecode.server.init"] = nil
  package.loaded["claudecode.tools.init"] = nil
  package.loaded["claudecode.diff"] = nil

  -- Mock the selection module before other modules might require it
  package.loaded["claudecode.selection"] = {
    get_latest_selection = function()
      return {
        file_path = "/test/selection.lua",
        content = "test selection content",
        start_line = 1,
        end_line = 1,
      }
    end,
  }

  -- Ensure _G.vim is initialized by busted_setup (can be asserted here or assumed)
  assert(_G.vim, "Global vim mock not initialized by busted_setup.lua")
  assert(_G.vim.fn, "Global vim.fn mock not initialized")
  assert(_G.vim.api, "Global vim.api mock not initialized")

  -- Load modules (these will now use the _G.vim provided by busted_setup and fresh caches)
  local server = require("claudecode.server.init")
  local tools = require("claudecode.tools.init")

  local original_vim_functions = {} -- To store original functions if we override them

  ---@class MCPToolInputSchemaProperty
  ---@field type string
  ---@field description string
  ---@field default any?

  ---@class MCPToolInputSchema
  ---@field type string
  ---@field properties table<string, MCPToolInputSchemaProperty>
  ---@field required string[]?

  ---@class MCPToolDefinition
  ---@field name string
  ---@field description string
  ---@field inputSchema MCPToolInputSchema
  ---@field outputSchema table? -- Simplified for now

  ---@class MCPResultContentItem
  ---@field type string
  ---@field text string?
  ---@field language string?
  ---@field source string? -- For images, etc.

  ---@class MCPToolResult
  ---@field content MCPResultContentItem[]?
  ---@field isError boolean?
  ---@field error table? -- Contains code, message, data (MCPErrorData structure)

  ---@class MCPErrorData
  ---@field code number
  ---@field message string
  ---@field data any?

  -- The setup() function's work is now done above.
  -- local function setup() ... end -- Removed

  local function teardown()
    -- Restore any original vim functions that were overridden in setup()
    for path, func in pairs(original_vim_functions) do
      local parts = {}
      for part in string.gmatch(path, "[^%.]+") do
        table.insert(parts, part)
      end
      local obj = _G.vim
      for i = 1, #parts - 1 do
        obj = obj[parts[i]]
      end
      obj[parts[#parts]] = func
    end
    original_vim_functions = {}
    -- _G.vim itself is managed by busted_setup.lua; no need to nil it here
    -- unless busted_setup doesn't restore it between spec files.
  end

  -- setup() -- Call removed as setup work is done at the top of describe

  describe("Tools List Handler", function()
    it("should return complete tool definitions", function()
      server.register_handlers()
      tools.setup(server)

      local handler = server.state.handlers["tools/list"]
      expect(handler).to_be_function()

      local result = handler(nil, {})

      expect(result.tools).to_be_table()
      expect(#result.tools).to_be_at_least(4)

      local openDiff_tool = nil
      for _, tool in ipairs(result.tools) do
        if tool.name == "openDiff" then
          openDiff_tool = tool
          break
        end
      end

      expect(openDiff_tool).not_to_be_nil()
      ---@cast openDiff_tool MCPToolDefinition
      expect(type(openDiff_tool.description)).to_be("string")
      expect(openDiff_tool.description:find("diff view")).to_be_truthy()
      expect(openDiff_tool.inputSchema).to_be_table()
      expect(openDiff_tool.inputSchema.type).to_be("object")
      expect(openDiff_tool.inputSchema.required).to_be_table()
      expect(#openDiff_tool.inputSchema.required).to_be(4)

      local required = openDiff_tool.inputSchema.required
      local has_old_file_path = false
      local has_new_file_path = false
      local has_new_file_contents = false
      local has_tab_name = false

      if required then
        for _, param in ipairs(required) do
          if param == "old_file_path" then
            has_old_file_path = true
          end
          if param == "new_file_path" then
            has_new_file_path = true
          end
          if param == "new_file_contents" then
            has_new_file_contents = true
          end
          if param == "tab_name" then
            has_tab_name = true
          end
        end
      end

      expect(has_old_file_path).to_be_true()
      expect(has_new_file_path).to_be_true()
      expect(has_new_file_contents).to_be_true()
      expect(has_tab_name).to_be_true()

      local props = openDiff_tool.inputSchema.properties
      expect(props.old_file_path.type).to_be("string")
      expect(props.new_file_path.type).to_be("string")
      expect(props.new_file_contents.type).to_be("string")
      expect(props.tab_name.type).to_be("string")
    end)

    it("should include other essential tools", function()
      server.register_handlers()
      tools.setup(server)

      local handler = server.state.handlers["tools/list"]
      local result = handler(nil, {})

      local tool_names = {}
      for _, tool in ipairs(result.tools) do
        table.insert(tool_names, tool.name)
      end

      local has_openFile = false
      local has_getCurrentSelection = false
      local has_getOpenEditors = false
      local has_openDiff = false

      for _, name in ipairs(tool_names) do
        if name == "openFile" then
          has_openFile = true
        end
        if name == "getCurrentSelection" then
          has_getCurrentSelection = true
        end
        if name == "getOpenEditors" then
          has_getOpenEditors = true
        end
        if name == "openDiff" then
          has_openDiff = true
        end
      end

      expect(has_openFile).to_be_true()
      expect(has_getCurrentSelection).to_be_true()
      expect(has_getOpenEditors).to_be_true()
      expect(has_openDiff).to_be_true()
    end)
  end)

  describe("Tools Call Handler", function()
    before_each(function()
      -- Mock the tools module to isolate handler logic.
      tools = {
        handle_invoke = function(client, params)
          if params.name == "openDiff" then
            local required_params = { "old_file_path", "new_file_path", "new_file_contents", "tab_name" }
            for _, param in ipairs(required_params) do
              if not params.arguments[param] then
                return {
                  result = {
                    content = {
                      {
                        type = "text",
                        text = "Error: Missing required parameter: " .. param,
                      },
                    },
                    isError = true,
                  },
                }
              end
            end

            return {
              result = {
                content = {
                  {
                    type = "text",
                    text = "Diff opened using native provider: " .. params.arguments.tab_name,
                  },
                },
              },
            }
          elseif params.name == "getOpenEditors" then
            return {
              result = {
                content = {
                  {
                    type = "text",
                    text = "[]",
                  },
                },
              },
            }
          elseif params.name == "openFile" then
            return {
              result = {
                content = {
                  {
                    type = "text",
                    text = "File opened: " .. params.arguments.filePath,
                  },
                },
              },
            }
          elseif params.name == "getCurrentSelection" then
            return {
              result = {
                content = {
                  {
                    type = "text",
                    text = '{"file_path": "/test/selection.lua", "content": "test selection content", "start_line": 1, "end_line": 1}',
                  },
                },
              },
            }
          else
            return {
              error = {
                code = -32601,
                message = "Tool not found: " .. params.name,
              },
            }
          end
        end,
      }

      server.register_handlers()

      -- Patch server's "tools/call" handler to use the mocked tools.handle_invoke.
      server.state.handlers["tools/call"] = function(client, params)
        local result_or_error_table = tools.handle_invoke(client, params)
        if result_or_error_table.error then
          return nil, result_or_error_table.error
        elseif result_or_error_table.result then
          return result_or_error_table.result, nil
        else
          return nil,
            {
              code = -32603,
              message = "Internal error",
              data = "Tool handler returned unexpected format",
            }
        end
      end
    end)

    it("should handle openDiff tool call successfully", function()
      -- Mock io.open for temporary file creation
      local mock_file = {
        write = function() end,
        close = function() end,
      }
      local old_io_open = io.open
      rawset(io, "open", function()
        return mock_file
      end)

      local handler = server.state.handlers["tools/call"]
      expect(handler).to_be_function()

      local params = {
        name = "openDiff",
        arguments = {
          old_file_path = "/test/old.lua",
          new_file_path = "/test/new.lua",
          new_file_contents = "function test()\n  return 'new'\nend",
          tab_name = "Integration Test Diff",
        },
      }

      local result, error_data = handler(nil, params)

      expect(result).to_be_table()
      ---@cast result MCPToolResult
      expect(error_data).to_be_nil()
      expect(result.content).to_be_table()
      expect(result.content[1].type).to_be("text")
      expect(type(result.content[1].text)).to_be("string")
      expect(result.content[1].text:find("Diff opened using")).to_be_truthy()
      expect(result.content[1].text:find("Integration Test Diff")).to_be_truthy()

      rawset(io, "open", old_io_open)
    end)

    it("should handle missing parameters in openDiff", function()
      local handler = server.state.handlers["tools/call"]

      local params = {
        name = "openDiff",
        arguments = {
          old_file_path = "/test/old.lua",
        },
      }

      local result, error_data = handler(nil, params)

      expect(result).to_be_table()
      expect(error_data).to_be_nil()
      expect(result.content).to_be_table()
      expect(result.content[1].type).to_be("text")
      expect(type(result.content[1].text)).to_be("string")
      expect(result.content[1].text:find("Missing required parameter")).to_be_truthy()
      expect(result.isError).to_be_true()
    end)

    it("should handle getOpenEditors tool call", function()
      local handler = server.state.handlers["tools/call"]

      local params = {
        name = "getOpenEditors",
        arguments = {},
      }

      local result, error_data = handler(nil, params)

      expect(result).to_be_table()
      expect(error_data).to_be_nil()
      expect(result.content).to_be_table()
      expect(result.content[1].type).to_be("text")
      expect(result.content[1].text).to_be_string() -- The JSON is encoded as text.
    end)

    it("should handle openFile tool call", function()
      local handler = server.state.handlers["tools/call"]

      local params = {
        name = "openFile",
        arguments = {
          filePath = "/test/existing.lua",
        },
      }

      local result, error_data = handler(nil, params)

      expect(result).to_be_table()
      expect(error_data).to_be_nil()
      expect(result.content).to_be_table()
      expect(result.content[1].type).to_be("text")
      expect(type(result.content[1].text)).to_be("string")
      expect(result.content[1].text:find("File opened")).to_be_truthy()
    end)

    it("should handle unknown tool gracefully", function()
      local handler = server.state.handlers["tools/call"]

      local params = {
        name = "unknownTool",
        arguments = {},
      }

      local result, error_data = handler(nil, params)

      expect(result).to_be_nil()
      expect(error_data).to_be_table()
      ---@cast error_data MCPErrorData
      expect(error_data.code).to_be(-32601)
      expect(type(error_data.message)).to_be("string")
      expect(error_data.message:find("Tool not found")).to_be_truthy()
    end)

    it("should handle tool execution errors", function()
      -- Temporarily replace the tools mock to simulate an error
      local error_tools = {
        handle_invoke = function(client, params)
          if params.name == "openDiff" then
            return {
              result = {
                content = {
                  {
                    type = "text",
                    text = "Error opening diff: Simulated diff error",
                  },
                },
                isError = true,
              },
            }
          else
            return {
              error = {
                code = -32601,
                message = "Tool not found: " .. params.name,
              },
            }
          end
        end,
      }

      -- Replace the handler with error behavior
      server.state.handlers["tools/call"] = function(client, params)
        local result_or_error_table = error_tools.handle_invoke(client, params)
        if result_or_error_table.error then
          return nil, result_or_error_table.error
        elseif result_or_error_table.result then
          return result_or_error_table.result, nil
        else
          return nil,
            {
              code = -32603,
              message = "Internal error",
              data = "Tool handler returned unexpected format",
            }
        end
      end

      local handler = server.state.handlers["tools/call"]

      local params = {
        name = "openDiff",
        arguments = {
          old_file_path = "/test/old.lua",
          new_file_path = "/test/new.lua",
          new_file_contents = "content",
          tab_name = "Error Test",
        },
      }

      local result, error_data = handler(nil, params)

      expect(result).to_be_table()
      expect(error_data).to_be_nil()
      expect(result.content).to_be_table()
      expect(result.content[1].type).to_be("text")
      expect(type(result.content[1].text)).to_be("string")
      expect(result.content[1].text:find("Error opening diff")).to_be_truthy()
      expect(result.isError).to_be_true()
    end)
  end)

  describe("End-to-End MCP Protocol Flow", function()
    it("should complete full openDiff workflow", function()
      -- Mock io.open for temporary file creation
      local temp_files_created = {} -- luacheck: ignore temp_files_created
      local mock_file = {
        write = function(self, content)
          self.content = content
        end,
        close = function() end,
      }
      local old_io_open = io.open
      rawset(io, "open", function(filename, mode)
        temp_files_created[filename] = { content = "", mode = mode }
        return mock_file
      end)

      -- Track vim commands
      local vim_commands = {}
      -- Save original _G.vim.cmd if it hasn't been backed up yet in original_vim_functions
      if _G.vim and rawget(original_vim_functions, "cmd") == nil then
        original_vim_functions["cmd"] = _G.vim.cmd -- Save current value (can be nil or function)
      end
      _G.vim.cmd = function(cmd)
        table.insert(vim_commands, cmd)
      end

      -- Use the same mock tools for end-to-end test
      tools = {
        get_tool_list = function()
          return {
            {
              name = "openDiff",
              description = "Open a diff view comparing old file content with new file content",
              inputSchema = {
                type = "object",
                required = { "old_file_path", "new_file_path", "new_file_contents", "tab_name" },
              },
            },
          }
        end,
        handle_invoke = function(client, params)
          if params.name == "openDiff" then
            local required_params = { "old_file_path", "new_file_path", "new_file_contents", "tab_name" }
            for _, param in ipairs(required_params) do
              if not params.arguments[param] then
                return {
                  result = {
                    content = {
                      {
                        type = "text",
                        text = "Error: Missing required parameter: " .. param,
                      },
                    },
                    isError = true,
                  },
                }
              end
            end

            return {
              result = {
                content = {
                  {
                    type = "text",
                    text = "Diff opened using native provider: " .. params.arguments.tab_name,
                  },
                },
              },
            }
          else
            return {
              error = {
                code = -32601,
                message = "Tool not found: " .. params.name,
              },
            }
          end
        end,
      }

      server.register_handlers()

      -- Replace the tools reference in server handlers
      server.state.handlers["tools/list"] = function(client, params)
        return {
          tools = tools.get_tool_list(),
        }
      end

      server.state.handlers["tools/call"] = function(client, params)
        local result_or_error_table = tools.handle_invoke(client, params)
        if result_or_error_table.error then
          return nil, result_or_error_table.error
        elseif result_or_error_table.result then
          return result_or_error_table.result, nil
        else
          return nil,
            {
              code = -32603,
              message = "Internal error",
              data = "Tool handler returned unexpected format",
            }
        end
      end

      local list_handler = server.state.handlers["tools/list"]
      local tools_list = list_handler(nil, {})

      expect(tools_list.tools).to_be_table()

      local call_handler = server.state.handlers["tools/call"]
      local call_params = {
        name = "openDiff",
        arguments = {
          old_file_path = "/project/src/utils.lua",
          new_file_path = "/project/src/utils.lua",
          new_file_contents = "-- Updated utils\nfunction utils.helper()\n  return 'updated'\nend",
          tab_name = "Utils Update",
        },
      }

      local call_result, call_error = call_handler(nil, call_params)

      expect(call_result).to_be_table()
      expect(call_error).to_be_nil()
      expect(call_result.content).to_be_table()
      expect(call_result.content[1].type).to_be("text")
      expect(type(call_result.content[1].text)).to_be("string")
      expect(call_result.content[1].text:find("Diff opened")).to_be_truthy()
      expect(call_result.content[1].text:find("Utils Update")).to_be_truthy()

      -- Note: With mock tools, we don't actually execute vim commands or create temp files
      -- but we can verify the response indicates success
      -- The actual diff functionality is tested in unit tests

      rawset(io, "open", old_io_open)

      -- Restore _G.vim.cmd to the state it was in before this test modified it.
      -- The original value (or nil) was stored in original_vim_functions["cmd"]
      -- by this test's setup logic (around line 472).
      if _G.vim and rawget(original_vim_functions, "cmd") ~= nil then
        -- Check if "cmd" key exists in original_vim_functions.
        -- This implies it was set by this test or a misbehaving prior one.
        _G.vim.cmd = original_vim_functions["cmd"]
        -- Nil out this entry to signify this specific override has been reverted,
        -- preventing the main file teardown (if it runs) from acting on it again
        -- or a subsequent test from being confused by this stale backup.
        original_vim_functions["cmd"] = nil
      end
    end)

    it("should handle parameter validation across the protocol", function()
      -- Use mock tools for parameter validation test
      tools = {
        handle_invoke = function(client, params)
          if params.name == "openDiff" then
            local required_params = { "old_file_path", "new_file_path", "new_file_contents", "tab_name" }
            for _, param in ipairs(required_params) do
              if not params.arguments[param] then
                return {
                  result = {
                    content = {
                      {
                        type = "text",
                        text = "Error: Missing required parameter: " .. param,
                      },
                    },
                    isError = true,
                  },
                }
              end
            end
            return {
              result = {
                content = {
                  {
                    type = "text",
                    text = "Diff opened successfully",
                  },
                },
              },
            }
          else
            return {
              error = {
                code = -32601,
                message = "Tool not found: " .. params.name,
              },
            }
          end
        end,
      }

      server.register_handlers()

      -- Replace the tools reference in server handlers
      server.state.handlers["tools/call"] = function(client, params)
        local result_or_error_table = tools.handle_invoke(client, params)
        if result_or_error_table.error then
          return nil, result_or_error_table.error
        elseif result_or_error_table.result then
          return result_or_error_table.result, nil
        else
          return nil,
            {
              code = -32603,
              message = "Internal error",
              data = "Tool handler returned unexpected format",
            }
        end
      end

      local call_handler = server.state.handlers["tools/call"]

      local required_params = { "old_file_path", "new_file_path", "new_file_contents", "tab_name" }

      for _, missing_param in ipairs(required_params) do
        local params = {
          name = "openDiff",
          arguments = {
            old_file_path = "/test/old.lua",
            new_file_path = "/test/new.lua",
            new_file_contents = "content",
            tab_name = "Test",
          },
        }
        params.arguments[missing_param] = nil

        local result, result_error = call_handler(nil, params)

        expect(result).to_be_table()
        expect(result_error).to_be_nil()
        expect(result.content).to_be_table()
        expect(result.content[1].type).to_be("text")
        expect(type(result.content[1].text)).to_be("string")
        expect(result.content[1].text:find("Missing required parameter: " .. missing_param)).to_be_truthy()
        expect(result.isError).to_be_true()
      end
    end)
  end)

  describe("Authentication Flow Integration", function()
    local test_auth_token = "550e8400-e29b-41d4-a716-446655440000"
    local config = {
      port_range = {
        min = 10000,
        max = 65535,
      },
    }

    -- Ensure clean state before each test
    before_each(function()
      if server.state.server then
        server.stop()
      end
    end)

    -- Clean up after each test
    after_each(function()
      if server.state.server then
        server.stop()
      end
    end)

    it("should start server with auth token", function()
      -- Start server with authentication
      local success, port = server.start(config, test_auth_token)
      expect(success).to_be_true()
      expect(server.state.auth_token).to_be(test_auth_token)
      expect(type(port)).to_be("number")

      -- Verify server is running with auth
      local status = server.get_status()
      expect(status.running).to_be_true()
      expect(status.port).to_be(port)

      -- Clean up
      server.stop()
    end)

    it("should handle authentication state across server lifecycle", function()
      -- Start with authentication
      local success1, _ = server.start(config, test_auth_token)
      expect(success1).to_be_true()
      expect(server.state.auth_token).to_be(test_auth_token)

      -- Stop server
      server.stop()
      expect(server.state.auth_token).to_be_nil()

      -- Start without authentication
      local success2, _ = server.start(config, nil)
      expect(success2).to_be_true()
      expect(server.state.auth_token).to_be_nil()

      -- Clean up
      server.stop()
    end)

    it("should handle different auth states", function()
      -- Test with authentication enabled
      local success1, _ = server.start(config, test_auth_token)
      expect(success1).to_be_true()
      expect(server.state.auth_token).to_be(test_auth_token)

      server.stop()

      -- Test with authentication disabled
      local success2, _ = server.start(config, nil)
      expect(success2).to_be_true()
      expect(server.state.auth_token).to_be_nil()

      -- Clean up
      server.stop()
    end)

    it("should preserve auth token during handler setup", function()
      -- Start server with auth token
      server.start(config, test_auth_token)
      expect(server.state.auth_token).to_be(test_auth_token)

      -- Register handlers - should not affect auth token
      server.register_handlers()
      expect(server.state.auth_token).to_be(test_auth_token)

      -- Get status - should not affect auth token
      local status = server.get_status()
      expect(status.running).to_be_true()
      expect(server.state.auth_token).to_be(test_auth_token)

      -- Clean up
      server.stop()
    end)

    it("should handle multiple auth token operations", function()
      -- Start server
      server.start(config, test_auth_token)
      expect(server.state.auth_token).to_be(test_auth_token)

      -- Multiple operations that should not affect auth token
      for i = 1, 5 do
        server.register_handlers()
        local status = server.get_status()
        expect(status.running).to_be_true()

        -- Auth token should remain stable
        expect(server.state.auth_token).to_be(test_auth_token)
      end

      -- Clean up
      server.stop()
    end)
  end)

  teardown()
end)
