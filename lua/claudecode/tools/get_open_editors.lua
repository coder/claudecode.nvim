--- Tool implementation for getting a list of open editors.

local schema = {
  description = "Get list of currently open files",
  inputSchema = {
    type = "object",
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

--- Handles the getOpenEditors tool invocation.
-- Gets a list of currently open and listed files in Neovim.
-- @param _params table The input parameters for the tool (currently unused).
-- @return table A list of open editor information.
local function handler(_params) -- Prefix unused params with underscore
  local tabs = {}
  local buffers = vim.api.nvim_list_bufs()
  local current_buf = vim.api.nvim_get_current_buf()

  for _, bufnr in ipairs(buffers) do
    -- Only include loaded, listed buffers with a file path
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.fn.buflisted(bufnr) == 1 then
      local file_path = vim.api.nvim_buf_get_name(bufnr)

      if file_path and file_path ~= "" then
        -- Get the filename for the label
        local label = vim.fn.fnamemodify(file_path, ":t")

        -- Get language ID (filetype)
        local language_id = vim.api.nvim_buf_get_option(bufnr, "filetype")
        if language_id == "" then
          language_id = "plaintext"
        end

        table.insert(tabs, {
          uri = "file://" .. file_path,
          isActive = bufnr == current_buf,
          label = label,
          languageId = language_id,
          isDirty = vim.api.nvim_buf_get_option(bufnr, "modified"),
        })
      end
    end
  end

  -- Return MCP-compliant format with JSON-stringified tabs array matching VS Code format
  return {
    content = {
      {
        type = "text",
        text = vim.json.encode({ tabs = tabs }, { indent = 2 }),
      },
    },
  }
end

return {
  name = "getOpenEditors",
  schema = schema,
  handler = handler,
}
