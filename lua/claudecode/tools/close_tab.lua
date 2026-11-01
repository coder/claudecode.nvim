--- Tool implementation for closing a Claude diff by its tab name.

-- Note: Schema defined but not used since this tool is internal
-- local schema = {
--   description = "Close a tab/buffer by its tab name",
--   inputSchema = {
--     type = "object",
--     properties = {
--       tab_name = {
--         type = "string",
--         description = "Name of the tab to close",
--       },
--     },
--     required = { "tab_name" },
--     additionalProperties = false,
--     ["$schema"] = "http://json-schema.org/draft-07/schema#",
--   },
-- }

---Handles the close_tab tool invocation.
---Closes the diff that openDiff opened with this tab name.
---@param params {tab_name: string} The input parameters for the tool
---@param client table|nil The calling WebSocket client (handle_invoke passes it)
---@return table success A result message indicating success
local function handler(params, client)
  local log_module_ok, log = pcall(require, "claudecode.logger")
  if not log_module_ok then
    return {
      code = -32603, -- Internal error
      message = "Internal error",
      data = "Failed to load logger module",
    }
  end

  log.debug("close_tab", "close_tab handler called")

  if not params.tab_name then
    log.error("close_tab", "Missing required parameter: tab_name")
    return {
      code = -32602, -- Invalid params
      message = "Invalid params",
      data = "Missing required parameter: tab_name",
    }
  end

  -- Claude passes the tab_name it gave openDiff, such as "✻ [Claude Code] README.md (e18e1e) ⧉". A name that
  -- matches no diff closes nothing, so close_tab never closes or deletes a buffer the user opened.
  local tab_name = params.tab_name
  log.debug("close_tab", "Attempting to close tab: " .. tab_name)

  local diff_module_ok, diff = pcall(require, "claudecode.diff")
  if diff_module_ok and diff.close_diff_by_tab_name then
    local closed = diff.close_diff_by_tab_name(tab_name, client and client.id or nil)
    if closed then
      log.debug("close_tab", "Successfully closed diff for tab: " .. tab_name)
    else
      log.debug("close_tab", "No diff to close for tab: " .. tab_name)
    end
  else
    log.error("close_tab", "Failed to load diff module or close_diff_by_tab_name not available")
  end

  -- VS Code also answers TAB_CLOSED when no tab matches, and Claude Code 2.1.312 does not read the text.
  return {
    content = {
      {
        type = "text",
        text = "TAB_CLOSED",
      },
    },
  }
end

return {
  name = "close_tab",
  schema = nil, -- Internal tool - must remain as requested by user
  handler = handler,
}
