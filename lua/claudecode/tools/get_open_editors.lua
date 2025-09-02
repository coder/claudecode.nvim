--- Tool implementation for getting a list of open editors.

local schema = {
  description = "Get list of currently open files",
  inputSchema = {
    type = "object",
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Handles the getOpenEditors tool invocation.
---Gets a list of currently open and listed files in Neovim.
---@return table response MCP-compliant response with editor tabs data
local function handler(params)
  local tabs = {}
  local buffers = vim.api.nvim_list_bufs()
  local current_buf = vim.api.nvim_get_current_buf()
  local current_tabpage = vim.api.nvim_get_current_tabpage()

  -- Get selection for active editor if available
  local active_selection = nil
  local selection_module_ok, selection_module = pcall(require, "claudecode.selection")
  if selection_module_ok then
    active_selection = selection_module.get_latest_selection()
  end

  for _, bufnr in ipairs(buffers) do
    -- Only include loaded, listed buffers with a file path
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.fn.buflisted(bufnr) == 1 then
      local file_path = vim.api.nvim_buf_get_name(bufnr)

      if file_path and file_path ~= "" then
        -- Get the filename for the label
        local ok_label, label = pcall(vim.fn.fnamemodify, file_path, ":t")
        if not ok_label then
          label = file_path -- Fallback to full path
        end

        -- Get language ID (filetype)
        local ok_lang, language_id = pcall(vim.api.nvim_buf_get_option, bufnr, "filetype")
        if not ok_lang or language_id == nil or language_id == "" then
          language_id = "plaintext"
        end

        -- Get line count
        local line_count = 0
        local ok_lines, lines_result = pcall(vim.api.nvim_buf_line_count, bufnr)
        if ok_lines then
          line_count = lines_result
        end

        -- Check if untitled (no file path or special buffer)
        local is_untitled = (
          not file_path
          or file_path == ""
          or string.match(file_path, "^%s*$") ~= nil
          or string.match(file_path, "^term://") ~= nil
          or string.match(file_path, "^%[.*%]$") ~= nil
        )

        -- Get tabpage info for this buffer
        -- For simplicity, use current tabpage as the "group" for all buffers
        -- In a more complex implementation, we could track which tabpage last showed each buffer
        local group_index = current_tabpage - 1 -- 0-based
        local view_column = current_tabpage -- 1-based
        local is_group_active = true -- Current tabpage is always active

        -- Build tab object with all VS Code fields
        local tab = {
          uri = "file://" .. file_path,
          isActive = bufnr == current_buf,
          isPinned = false, -- Neovim doesn't have pinned tabs
          isPreview = false, -- Neovim doesn't have preview tabs
          isDirty = (function()
            local ok, modified = pcall(vim.api.nvim_buf_get_option, bufnr, "modified")
            return ok and modified or false
          end)(),
          label = label,
          groupIndex = group_index,
          viewColumn = view_column,
          isGroupActive = is_group_active,
          fileName = file_path,
          languageId = language_id,
          lineCount = line_count,
          isUntitled = is_untitled,
        }

        -- Add selection info for active editor
        if bufnr == current_buf and active_selection and active_selection.selection then
          tab.selection = {
            start = active_selection.selection.start,
            ["end"] = active_selection.selection["end"],
            isReversed = false, -- Neovim doesn't track reversed selections like VS Code
          }
        end

        table.insert(tabs, tab)
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
