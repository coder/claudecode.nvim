--- Tool implementation for getting diagnostics.

-- NOTE: Its important we don't tip off Claude that we're dealing with Neovim LSP diagnostics because it may adjust
-- line and col numbers by 1 on its own (since it knows nvim LSP diagnostics are 0-indexed). By calling these
-- "editor diagnostics" and converting to 1-indexed ourselves we (hopefully) avoid incorrect line and column numbers
-- in Claude's responses.
local schema = {
  description = "Get language diagnostics (errors, warnings) from the editor",
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
      data = "Diagnostics not available in this editor version/configuration.",
    })
  end

  local logger = require("claudecode.logger")

  logger.debug("getDiagnostics handler called with params: " .. vim.inspect(params))

  -- Extract the uri parameter
  local diagnostics

  if not params.uri then
    -- Get diagnostics for all buffers
    logger.debug("Getting diagnostics for all open buffers")
    diagnostics = vim.diagnostic.get(nil)
  else
    local uri = params.uri
    -- Strips the file:// scheme
    local filepath = vim.uri_to_fname(uri)

    -- Get buffer number for the specific file
    local bufnr = vim.fn.bufnr(filepath)
    if bufnr == -1 then
      -- File is not open in any buffer, throw an error
      logger.debug("File buffer must be open to get diagnostics: " .. filepath)
      error({
        code = -32001,
        message = "File not open",
        data = "File must be open to retrieve diagnostics: " .. filepath,
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
        text = vim.json.encode({
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
