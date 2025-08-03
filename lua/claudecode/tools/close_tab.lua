--- Tool implementation for closing a buffer by its name.

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
---Closes a tab/buffer by its tab name.
---@param params {tab_name: string} The input parameters for the tool
---@return table success A result message indicating success
local function handler(params)
  local log_module_ok, log = pcall(require, "claudecode.logger")
  if not log_module_ok then
    return {
      code = -32603, -- Internal error
      message = "Internal error",
      data = "Failed to load logger module",
    }
  end

  log.debug("close_tab handler called with params: " .. vim.inspect(params))

  if not params.tab_name then
    log.error("Missing required parameter: tab_name")
    return {
      code = -32602, -- Invalid params
      message = "Invalid params",
      data = "Missing required parameter: tab_name",
    }
  end

  -- Extract the actual file name from the tab name
  -- Tab name format: "✻ [Claude Code] README.md (e18e1e) ⧉"
  -- We need to extract "README.md" or the full path
  local tab_name = params.tab_name
  log.debug("Attempting to close tab: " .. tab_name)

  -- Check if this is a diff tab (contains ✻ and ⧉ markers)
  if tab_name:match("✻") and tab_name:match("⧉") then
    log.debug("Detected diff tab - closing diff view")

    -- Try to close the diff
    local diff_module_ok, diff = pcall(require, "claudecode.diff")
    if diff_module_ok and diff.close_diff_by_tab_name then
      local closed = diff.close_diff_by_tab_name(tab_name)
      if closed then
        log.debug("Successfully closed diff for tab: " .. tab_name)
        return {
          content = {
            {
              type = "text",
              text = "TAB_CLOSED",
            },
          },
        }
      else
        log.debug("Diff not found for tab: " .. tab_name)
        return {
          content = {
            {
              type = "text",
              text = "TAB_CLOSED",
            },
          },
        }
      end
    else
      log.error("Failed to load diff module or close_diff_by_tab_name not available")
      return {
        content = {
          {
            type = "text",
            text = "TAB_CLOSED",
          },
        },
      }
    end
  end

  -- Try to find buffer by the tab name first
  local bufnr = vim.fn.bufnr(tab_name)

  if bufnr == -1 then
    -- If not found, try to extract filename from the tab name
    -- Look for pattern like "filename.ext" in the tab name
    local filename = tab_name:match("([%w%.%-_]+%.[%w]+)")
    if filename then
      log.debug("Extracted filename from tab name: " .. filename)
      -- Try to find buffer by filename
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        local buf_name = vim.api.nvim_buf_get_name(buf)
        if buf_name:match(filename .. "$") then
          bufnr = buf
          log.debug("Found buffer by filename match: " .. buf_name)
          break
        end
      end
    end
  end

  if bufnr == -1 then
    -- If buffer not found, the tab might already be closed - treat as success
    log.debug("Buffer not found for tab (already closed?): " .. tab_name)
    return {
      content = {
        {
          type = "text",
          text = "TAB_CLOSED",
        },
      },
    }
  end

  local success, err = pcall(vim.api.nvim_buf_delete, bufnr, { force = false })

  if not success then
    log.error("Failed to close buffer: " .. tostring(err))
    return {
      code = -32000,
      message = "Buffer operation error",
      data = "Failed to close buffer for tab " .. tab_name .. ": " .. tostring(err),
    }
  end

  log.info("Successfully closed tab: " .. tab_name)

  -- Return MCP-compliant format matching VS Code extension
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
