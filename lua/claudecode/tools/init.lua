-- Tool implementation for Claude Code Neovim integration
local M = {}

M.ERROR_CODES = {
  PARSE_ERROR = -32700,
  INVALID_REQUEST = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS = -32602,
  INTERNAL_ERROR = -32000, -- Default for tool execution if not more specific
  -- Custom / server specific: -32000 to -32099
}

M.tools = {}

function M.setup(server)
  M.server = server

  M.register_all()
end

--- Get the complete tool list for MCP tools/list handler
function M.get_tool_list()
  local tool_list = {}

  for name, tool_data in pairs(M.tools) do
    -- Only include tools that have schemas (are meant to be exposed via MCP)
    if tool_data.schema then
      local tool_def = {
        name = name,
        description = tool_data.schema.description,
        inputSchema = tool_data.schema.inputSchema,
      }
      table.insert(tool_list, tool_def)
    end
  end

  return tool_list
end

function M.register_all()
  -- Register MCP-exposed tools with schemas
  M.register(require("claudecode.tools.open_file"))
  M.register(require("claudecode.tools.get_current_selection"))
  M.register(require("claudecode.tools.get_open_editors"))
  M.register(require("claudecode.tools.open_diff"))

  -- Register internal tools without schemas (not exposed via MCP)
  M.register(require("claudecode.tools.get_diagnostics"))
  M.register(require("claudecode.tools.get_workspace_folders"))
  -- M.register("getLatestSelection", nil, M.get_latest_selection) -- This tool is effectively covered by getCurrentSelection
  M.register(require("claudecode.tools.check_document_dirty"))
  M.register(require("claudecode.tools.save_document"))
  M.register(require("claudecode.tools.close_tab"))
end

function M.register(tool_module)
  if not tool_module or not tool_module.name or not tool_module.handler then
    local name = "unknown"
    if type(tool_module) == "table" and type(tool_module.name) == "string" then
      name = tool_module.name
    elseif type(tool_module) == "string" then -- if require failed, it might be the path string
      name = tool_module
    end
    vim.notify(
      "Error registering tool: Invalid tool module structure for " .. name,
      vim.log.levels.ERROR,
      { title = "ClaudeCode Tool Registration" }
    )
    return
  end

  M.tools[tool_module.name] = {
    handler = tool_module.handler,
    schema = tool_module.schema, -- Will be nil if not defined in the module
    requires_coroutine = tool_module.requires_coroutine, -- Will be nil if not defined in the module
  }
end

function M.handle_invoke(client, params) -- client needed for blocking tools
  local tool_name = params.name
  local input = params.arguments

  if not M.tools[tool_name] then
    return {
      error = {
        code = -32601, -- JSON-RPC Method not found
        message = "Tool not found: " .. tool_name,
      },
    }
  end

  local tool_data = M.tools[tool_name]
  -- Tool handlers are now expected to:
  -- 1. Raise an error (e.g., error({code=..., message=...}) or error("string"))
  -- 2. Return (false, "error message string" or {code=..., message=...}) for pcall-style errors
  -- 3. Return the result directly for success.
  -- Check if this tool requires coroutine context for blocking behavior
  local pcall_results
  if tool_data.requires_coroutine then
    -- Wrap in coroutine for blocking behavior
    require("claudecode.logger").debug("tools", "Wrapping " .. tool_name .. " in coroutine for blocking behavior")
    local co = coroutine.create(function()
      return tool_data.handler(input)
    end)

    require("claudecode.logger").debug("tools", "About to resume coroutine for " .. tool_name)
    local success, result = coroutine.resume(co)
    require("claudecode.logger").debug(
      "tools",
      "Coroutine resume returned - success:",
      success,
      "status:",
      coroutine.status(co)
    )

    if coroutine.status(co) == "suspended" then
      require("claudecode.logger").debug("tools", "Coroutine is suspended - tool is blocking, will respond later")
      -- The coroutine yielded, which means the tool is blocking
      -- Return a special marker to indicate this is a deferred response
      return { _deferred = true, coroutine = co, client = client, params = params }
    end

    require("claudecode.logger").debug(
      "tools",
      "Coroutine completed for " .. tool_name .. ", success: " .. tostring(success)
    )
    pcall_results = { success, result }
  else
    pcall_results = { pcall(tool_data.handler, input) }
  end
  local pcall_success = pcall_results[1]
  local handler_return_val1 = pcall_results[2]
  local handler_return_val2 = pcall_results[3]

  if not pcall_success then
    -- Case 1: Handler itself raised a Lua error (e.g. error("foo") or error({...}))
    -- handler_return_val1 contains the error object/string from the pcall
    local err_code = M.ERROR_CODES.INTERNAL_ERROR
    local err_msg = "Tool execution failed via error()"
    local err_data_payload = tostring(handler_return_val1)

    if type(handler_return_val1) == "table" and handler_return_val1.code and handler_return_val1.message then
      err_code = handler_return_val1.code
      err_msg = handler_return_val1.message
      err_data_payload = handler_return_val1.data
    elseif type(handler_return_val1) == "string" then
      err_msg = handler_return_val1
    end
    return { error = { code = err_code, message = err_msg, data = err_data_payload } }
  end

  -- pcall succeeded, now check the handler's actual return values
  -- Case 2: Handler returned (false, "error message" or {error_obj})
  if handler_return_val1 == false then
    local err_val_from_handler = handler_return_val2 -- This is the actual error string or table
    local err_code = M.ERROR_CODES.INTERNAL_ERROR
    local err_msg = "Tool reported an error"
    local err_data_payload = tostring(err_val_from_handler)

    if type(err_val_from_handler) == "table" and err_val_from_handler.code and err_val_from_handler.message then
      err_code = err_val_from_handler.code
      err_msg = err_val_from_handler.message
      err_data_payload = err_val_from_handler.data
    elseif type(err_val_from_handler) == "string" then
      err_msg = err_val_from_handler
    end
    return { error = { code = err_code, message = err_msg, data = err_data_payload } }
  end

  -- Case 3: Handler succeeded and returned the result directly
  -- handler_return_val1 is the actual result
  return { result = handler_return_val1 }
end

return M
