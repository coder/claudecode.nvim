--- Tool implementation for closing all diff tabs.

local schema = {
  description = "Close all diff tabs in the editor",
  inputSchema = {
    type = "object",
    additionalProperties = false,
    ["$schema"] = "http://json-schema.org/draft-07/schema#",
  },
}

---Handles the closeAllDiffTabs tool invocation.
---Closes all diff tabs/windows in the editor.
---@return table response MCP-compliant response with content array indicating number of closed tabs.
local function handler(params)
  -- Resolve all pending diffs as rejected so coroutines are properly resumed
  -- (cleanup_all_active_diffs would delete state without invoking callbacks,
  -- leaving open_diff_blocking coroutines hanging on yield)
  local closed_count = 0

  local diff_ok, diff_module = pcall(require, "claudecode.diff")
  if diff_ok then
    local active = diff_module._get_active_diffs()
    local tab_names = {}
    for tab_name, _ in pairs(active) do
      table.insert(tab_names, tab_name)
    end
    for _, tab_name in ipairs(tab_names) do
      pcall(diff_module._resolve_diff_as_rejected, tab_name)
      pcall(diff_module._cleanup_diff_state, tab_name, "closeAllDiffTabs")
      closed_count = closed_count + 1
    end
  end

  -- Get all windows
  local windows = vim.api.nvim_list_wins()
  local windows_to_close = {} -- Use set to avoid duplicates

  for _, win in ipairs(windows) do
    local buf = vim.api.nvim_win_get_buf(win)
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
    local diff_mode = vim.api.nvim_win_get_option(win, "diff")
    local should_close = false

    -- Check if this is a diff window
    if diff_mode then
      should_close = true
    end

    -- Check for inline diff buffers
    local is_inline = vim.b[buf].claudecode_inline_diff
    if is_inline then
      should_close = true
    end

    -- Also check for diff-related buffer names or types
    local buf_name = vim.api.nvim_buf_get_name(buf)
    if buf_name:match("%.diff$") or buf_name:match("diff://") then
      should_close = true
    end

    -- Check for special diff buffer types
    if buftype == "nofile" and buf_name:match("^fugitive://") then
      should_close = true
    end

    -- Add to close set only once (prevents duplicates)
    if should_close then
      windows_to_close[win] = true
    end
  end

  -- Close the identified diff windows
  for win, _ in pairs(windows_to_close) do
    if vim.api.nvim_win_is_valid(win) then
      local success = pcall(vim.api.nvim_win_close, win, false)
      if success then
        closed_count = closed_count + 1
      end
    end
  end

  -- Also check for buffers that might be diff-related but not currently in windows
  local buffers = vim.api.nvim_list_bufs()
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      local buftype = vim.api.nvim_buf_get_option(buf, "buftype")

      -- Check for diff-related buffers
      if
        buf_name:match("%.diff$")
        or buf_name:match("diff://")
        or (buftype == "nofile" and buf_name:match("^fugitive://"))
      then
        -- Delete the buffer if it's not in any window
        local buf_windows = vim.fn.win_findbuf(buf)
        if #buf_windows == 0 then
          local success = pcall(vim.api.nvim_buf_delete, buf, { force = true })
          if success then
            closed_count = closed_count + 1
          end
        end
      end
    end
  end

  -- Return MCP-compliant format matching VS Code extension
  return {
    content = {
      {
        type = "text",
        text = "CLOSED_" .. closed_count .. "_DIFF_TABS",
      },
    },
  }
end

return {
  name = "closeAllDiffTabs",
  schema = schema,
  handler = handler,
}
