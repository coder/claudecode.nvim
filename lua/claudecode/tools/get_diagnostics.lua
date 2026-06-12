--- Tool implementation for getting diagnostics.

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

local severity_names = {
  [1] = "Error",
  [2] = "Warning",
  [3] = "Info",
  [4] = "Hint",
}

local function starts_with(str, prefix)
  return type(str) == "string" and str:sub(1, #prefix) == prefix
end

local function path_to_uri(path)
  if vim.uri_from_fname then
    return vim.uri_from_fname(path)
  end
  return "file://" .. path
end

local function severity_name(severity)
  if type(severity) == "string" then
    return severity
  end
  return severity_names[severity] or "Info"
end

local function diagnostic_range(diagnostic)
  local start_line = diagnostic.lnum or 0
  local start_col = diagnostic.col or 0
  local end_line = diagnostic.end_lnum or start_line
  local end_col = diagnostic.end_col or (start_col + 1)

  return {
    start = { line = start_line, character = start_col },
    ["end"] = { line = end_line, character = end_col },
  }
end

local function get_diagnostic_path(diagnostic, fallback_path)
  if diagnostic.bufnr then
    local file_path = vim.api.nvim_buf_get_name(diagnostic.bufnr)
    if file_path and file_path ~= "" then
      return file_path
    end
  end
  return fallback_path
end

local function append_diagnostic(files, file_by_uri, file_path, diagnostic)
  if not file_path or file_path == "" then
    return
  end

  local uri = path_to_uri(file_path)
  local file = file_by_uri[uri]
  if not file then
    file = { uri = uri, diagnostics = {} }
    file_by_uri[uri] = file
    table.insert(files, file)
  end

  table.insert(file.diagnostics, {
    message = diagnostic.message or "",
    severity = severity_name(diagnostic.severity),
    range = diagnostic_range(diagnostic),
    source = diagnostic.source,
    code = diagnostic.code and tostring(diagnostic.code) or nil,
  })
end

---Handles the getDiagnostics tool invocation.
---Retrieves diagnostics from Neovim's diagnostic system.
---@param params table The input parameters for the tool
---@return table diagnostics MCP-compliant response with diagnostics data
local function handler(params)
  if not vim.lsp or not vim.diagnostic or not vim.diagnostic.get then
    error({
      code = -32000,
      message = "Feature unavailable",
      data = "Diagnostics not available in this editor version/configuration.",
    })
  end

  local logger = require("claudecode.logger")

  logger.debug("getDiagnostics handler called with params: " .. vim.inspect(params))

  local diagnostics
  local fallback_path

  if not params.uri then
    logger.debug("Getting diagnostics for all open buffers")
    diagnostics = vim.diagnostic.get(nil)
  else
    local uri = params.uri
    fallback_path = starts_with(uri, "file://") and vim.uri_to_fname(uri) or uri

    local bufnr = vim.fn.bufnr(fallback_path)
    if bufnr == -1 then
      logger.debug("File buffer must be open to get diagnostics: " .. fallback_path)
      error({
        code = -32001,
        message = "File not open",
        data = "File must be open to retrieve diagnostics: " .. fallback_path,
      })
    end

    logger.debug("Getting diagnostics for bufnr: " .. bufnr)
    diagnostics = vim.diagnostic.get(bufnr)
  end

  local files = {}
  local file_by_uri = {}

  for _, diagnostic in ipairs(diagnostics or {}) do
    append_diagnostic(files, file_by_uri, get_diagnostic_path(diagnostic, fallback_path), diagnostic)
  end

  return {
    content = {
      {
        type = "text",
        text = vim.json.encode(files),
      },
    },
  }
end

return {
  name = "getDiagnostics",
  schema = schema,
  handler = handler,
}
