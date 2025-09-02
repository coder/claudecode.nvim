--- Tool implementation for opening a diff view.

local schema = {
  description = "Open a diff view comparing old file content with new file content",
  inputSchema = {
    type = "object",
    properties = {
      old_file_path = {
        type = "string",
        description = "Path to the old file to compare",
      },
      new_file_path = {
        type = "string",
        description = "Path to the new file to compare",
      },
      new_file_contents = {
        type = "string",
        description = "Contents for the new file version",
      },
      tab_name = {
        type = "string",
        description = "Name for the diff tab/view",
      },
    },
    required = { "old_file_path", "new_file_path", "new_file_contents", "tab_name" },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Handles the openDiff tool invocation with MCP compliance.
---Opens a diff view and blocks until user interaction (save/close).
---Returns MCP-compliant response with content array format.
---@param params table The input parameters for the tool
---@return table response MCP-compliant response with content array
local function handler(params)
  -- Validate required parameters
  local required_params = { "old_file_path", "new_file_path", "new_file_contents", "tab_name" }
  for _, param_name in ipairs(required_params) do
    if not params[param_name] then
      error({
        code = -32602, -- Invalid params
        message = "Invalid params",
        data = "Missing required parameter: " .. param_name,
      })
    end
  end

  -- Ensure we're running in a coroutine context for blocking operation
  local co, is_main = coroutine.running()
  if not co or is_main then
    error({
      code = -32000,
      message = "Internal server error",
      data = "openDiff must run in coroutine context",
    })
  end

  local diff_module_ok, diff_module = pcall(require, "claudecode.diff")
  if not diff_module_ok then
    error({ code = -32000, message = "Internal server error", data = "Failed to load diff module" })
  end

  -- Use the new blocking diff operation
  local success, result = pcall(
    diff_module.open_diff_blocking,
    params.old_file_path,
    params.new_file_path,
    params.new_file_contents,
    params.tab_name
  )

  if not success then
    -- Check if this is already a structured error
    if type(result) == "table" and result.code then
      error(result)
    else
      error({
        code = -32000, -- Generic tool error
        message = "Error opening blocking diff",
        data = tostring(result),
      })
    end
  end

  -- result should already be MCP-compliant with content array format
  return result
end

return {
  name = "openDiff",
  schema = schema,
  handler = handler,
  requires_coroutine = true, -- This tool needs coroutine context for blocking behavior
}
