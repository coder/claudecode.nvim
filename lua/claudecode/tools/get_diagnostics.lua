--- Tool implementation for getting diagnostics.

local schema = {
  description = "Get Neovim LSP diagnostics (errors, warnings) from open buffers",
  inputSchema = {
    type = "object",
    properties = {
      uri = {
        type = "string",
        description = "Optional file URI to get diagnostics for. If not provided, gets diagnostics for all open files.",
      },
    },
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

--- Handles the getDiagnostics tool invocation.
-- Retrieves diagnostics from Neovim's diagnostic system.
-- @param params table The input parameters for the tool.
-- @field params.uri string|nil Optional file URI to get diagnostics for.
-- @return table A table containing the list of diagnostics.
-- @error table A table with code, message, and data for JSON-RPC error if failed.
local function handler(params)
  if not vim.lsp or not vim.diagnostic or not vim.diagnostic.get then
    -- Returning an empty list or a specific status could be an alternative.
    -- For now, let's align with the error pattern for consistency if the feature is unavailable.
    error({
      code = -32000,
      message = "Feature unavailable",
      data = "LSP or vim.diagnostic.get not available in this Neovim version/configuration.",
    })
  end

  local logger = require("claudecode.logger")

  logger.debug("getDiagnostics handler called with params: " .. vim.inspect(params))

  -- Extract the uri parameter
  local diagnostics

  if not params.uri then
    -- Get diagnostics for all buffers
    diagnostics = vim.diagnostic.get()
    logger.debug("Getting diagnostics for all open buffers")
  else
    -- Remove file:// prefix if present
    local uri = params.uri
    local filepath = uri
    if uri:sub(1, 7) == "file://" then
      filepath = uri:sub(8) -- Remove "file://" prefix
    end

    -- Get buffer number for the specific file
    local bufnr = vim.fn.bufnr(filepath)
    if bufnr == -1 then
      -- File is not open in any buffer, throw an error
      logger.debug("File buffer must be open to get diagnostics: " .. filepath)
      error({
        code = -32001,
        message = "File not open in buffer",
        data = "File must be open in Neovim to retrieve diagnostics: " .. filepath,
      })
    else
      -- Get diagnostics for the specific buffer
      logger.debug("Getting diagnostics for bufnr: " .. bufnr)
      diagnostics = vim.diagnostic.get(bufnr)
    end
  end

  local formatted_diagnostics = {}
  for _, diagnostic in ipairs(diagnostics) do
    local file_path = vim.api.nvim_buf_get_name(diagnostic.bufnr)
    -- Ensure we only include diagnostics with valid file paths
    if file_path and file_path ~= "" then
      table.insert(formatted_diagnostics, {
        type = "text",
        -- json encode this
        text = vim.fn.json_encode({
          -- Use the file path and diagnostic information
          filePath = file_path,
          -- Convert line and column to 1-indexed
          line = diagnostic.lnum + 1,
          character = diagnostic.col + 1,
          severity = diagnostic.severity, -- e.g., vim.diagnostic.severity.ERROR
          message = diagnostic.message,
          source = diagnostic.source,
        }),
      })
    end
  end

  return {
    content = formatted_diagnostics,
  }
end

return {
  name = "getDiagnostics",
  schema = schema,
  handler = handler,
}
