--- Diff module for Claude Code Neovim integration.
-- Provides native Neovim diff functionality with MCP-compliant blocking operations and state management.
local M = {}

-- Global state management for active diffs
local active_diffs = {}
local autocmd_group

--- Get or create the autocmd group
local function get_autocmd_group()
  if not autocmd_group then
    autocmd_group = vim.api.nvim_create_augroup("ClaudeCodeMCPDiff", { clear = true })
  end
  return autocmd_group
end

--- Find a suitable main editor window to open diffs in.
-- Excludes terminals, sidebars, and floating windows.
-- @return number|nil Window ID of the main editor window, or nil if not found
function M._find_main_editor_window()
  local windows = vim.api.nvim_list_wins()

  for _, win in ipairs(windows) do
    local buf = vim.api.nvim_win_get_buf(win)
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
    local filetype = vim.api.nvim_buf_get_option(buf, "filetype")
    local win_config = vim.api.nvim_win_get_config(win)

    -- Check if this is a suitable window
    local is_suitable = true

    -- Skip floating windows
    if win_config.relative and win_config.relative ~= "" then
      is_suitable = false
    end

    -- Skip special buffer types
    if is_suitable and (buftype == "terminal" or buftype == "prompt") then
      is_suitable = false
    end

    -- Skip known sidebar filetypes and ClaudeCode terminal
    if
      is_suitable
      and (
        filetype == "neo-tree"
        or filetype == "neo-tree-popup"
        or filetype == "ClaudeCode"
        or filetype == "NvimTree"
        or filetype == "aerial"
        or filetype == "tagbar"
      )
    then
      is_suitable = false
    end

    -- This looks like a main editor window
    if is_suitable then
      return win
    end
  end

  return nil
end

--- Setup the diff module
-- @param user_diff_config table|nil Reserved for future use
function M.setup(user_diff_config)
  -- Currently no configuration needed for native diff
  -- Parameter kept for API compatibility
end

--- Open a diff view between two files
-- @param old_file_path string Path to the original file
-- @param new_file_path string Path to the new file (used for naming)
-- @param new_file_contents string Contents of the new file
-- @param tab_name string Name for the diff tab/view
-- @return table Result with provider, tab_name, and success status
function M.open_diff(old_file_path, new_file_path, new_file_contents, tab_name)
  return M._open_native_diff(old_file_path, new_file_path, new_file_contents, tab_name)
end

--- Create a temporary file with content
-- @param content string The content to write
-- @param filename string Base filename for the temporary file
-- @return string|nil, string|nil The temporary file path and error message
function M._create_temp_file(content, filename)
  local base_dir_cache = vim.fn.stdpath("cache") .. "/claudecode_diffs"
  local mkdir_ok_cache, mkdir_err_cache = pcall(vim.fn.mkdir, base_dir_cache, "p")

  local final_base_dir
  if mkdir_ok_cache then
    final_base_dir = base_dir_cache
  else
    local base_dir_temp = vim.fn.stdpath("cache") .. "/claudecode_diffs_fallback"
    local mkdir_ok_temp, mkdir_err_temp = pcall(vim.fn.mkdir, base_dir_temp, "p")
    if not mkdir_ok_temp then
      local err_to_report = mkdir_err_temp or mkdir_err_cache or "unknown error creating base temp dir"
      return nil, "Failed to create base temporary directory: " .. tostring(err_to_report)
    end
    final_base_dir = base_dir_temp
  end

  local session_id_base = vim.fn.fnamemodify(vim.fn.tempname(), ":t")
    .. "_"
    .. tostring(os.time())
    .. "_"
    .. tostring(math.random(1000, 9999))
  local session_id = session_id_base:gsub("[^A-Za-z0-9_-]", "")
  if session_id == "" then -- Fallback if all characters were problematic, ensuring a directory can be made.
    session_id = "claudecode_session"
  end

  local tmp_session_dir = final_base_dir .. "/" .. session_id
  local mkdir_session_ok, mkdir_session_err = pcall(vim.fn.mkdir, tmp_session_dir, "p")
  if not mkdir_session_ok then
    return nil, "Failed to create temporary session directory: " .. tostring(mkdir_session_err)
  end

  local tmp_file = tmp_session_dir .. "/" .. filename
  local file = io.open(tmp_file, "w")
  if not file then
    return nil, "Failed to create temporary file: " .. tmp_file
  end

  file:write(content)
  file:close()

  return tmp_file, nil
end

--- Clean up temporary files and directories
-- @param tmp_file string Path to the temporary file to clean up
function M._cleanup_temp_file(tmp_file)
  if tmp_file and vim.fn.filereadable(tmp_file) == 1 then
    local tmp_dir = vim.fn.fnamemodify(tmp_file, ":h")
    if vim.fs and type(vim.fs.remove) == "function" then
      local ok_file, err_file = pcall(vim.fs.remove, tmp_file)
      if not ok_file then
        vim.notify(
          "ClaudeCode: Error removing temp file " .. tmp_file .. ": " .. tostring(err_file),
          vim.log.levels.WARN
        )
      end

      local ok_dir, err_dir = pcall(vim.fs.remove, tmp_dir)
      if not ok_dir then
        vim.notify(
          "ClaudeCode: Error removing temp directory " .. tmp_dir .. ": " .. tostring(err_dir),
          vim.log.levels.INFO
        )
      end
    else
      local reason = "vim.fs.remove is not a function"
      if not vim.fs then
        reason = "vim.fs is nil"
      end
      vim.notify(
        "ClaudeCode: Cannot perform standard cleanup: "
          .. reason
          .. ". Affected file: "
          .. tmp_file
          .. ". Please check your Neovim setup or report this issue.",
        vim.log.levels.ERROR
      )
      -- Fallback to os.remove for the file.
      local os_ok, os_err = pcall(os.remove, tmp_file)
      if not os_ok then
        vim.notify(
          "ClaudeCode: Fallback os.remove also failed for file " .. tmp_file .. ": " .. tostring(os_err),
          vim.log.levels.ERROR
        )
      end
    end
  end
end

--- Clean up diff layout by properly restoring original single-window state
-- @param tab_name string The diff identifier for logging
-- @param target_win number The original window that was split
-- @param new_win number The new window created by the split
function M._cleanup_diff_layout(tab_name, target_win, new_win)
  require("claudecode.logger").debug("diff", "[CLEANUP] Starting layout cleanup for:", tab_name)
  require("claudecode.logger").debug("diff", "[CLEANUP] Target window:", target_win, "New window:", new_win)

  -- Store the current window before any operations
  local original_current_win = vim.api.nvim_get_current_win()
  require("claudecode.logger").debug("diff", "[CLEANUP] Original current window:", original_current_win)

  -- Turn off diff mode for both windows if they still exist
  if vim.api.nvim_win_is_valid(target_win) then
    vim.api.nvim_win_call(target_win, function()
      vim.cmd("diffoff")
    end)
    require("claudecode.logger").debug("diff", "[CLEANUP] Turned off diff mode for target window")
  end

  if vim.api.nvim_win_is_valid(new_win) then
    vim.api.nvim_win_call(new_win, function()
      vim.cmd("diffoff")
    end)
    require("claudecode.logger").debug("diff", "[CLEANUP] Turned off diff mode for new window")
  end

  -- Close the new split window, leaving the original window
  if vim.api.nvim_win_is_valid(new_win) then
    vim.api.nvim_set_current_win(new_win)
    vim.cmd("close")
    require("claudecode.logger").debug("diff", "[CLEANUP] Closed new split window")

    -- Return to the most appropriate window
    if vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
      require("claudecode.logger").debug("diff", "[CLEANUP] Returned to target window")
    elseif vim.api.nvim_win_is_valid(original_current_win) and original_current_win ~= new_win then
      -- Prefer returning to the original window if it wasn't the closed window
      vim.api.nvim_set_current_win(original_current_win)
      require("claudecode.logger").debug("diff", "[CLEANUP] Returned to original current window")
    else
      -- Find any valid window to focus on
      local windows = vim.api.nvim_list_wins()
      if #windows > 0 then
        vim.api.nvim_set_current_win(windows[1])
        require("claudecode.logger").debug("diff", "[CLEANUP] Set focus to first available window")
      end
    end
  end

  require("claudecode.logger").debug("diff", "[CLEANUP] Layout cleanup completed for:", tab_name)
end

--- Open diff using native Neovim functionality
-- @param old_file_path string Path to the original file
-- @param new_file_path string Path to the new file (used for naming)
-- @param new_file_contents string Contents of the new file
-- @param tab_name string Name for the diff tab/view
-- @return table Result with provider, tab_name, and success status
function M._open_native_diff(old_file_path, new_file_path, new_file_contents, tab_name)
  local new_filename = vim.fn.fnamemodify(new_file_path, ":t") .. ".new"
  local tmp_file, err = M._create_temp_file(new_file_contents, new_filename)
  if not tmp_file then
    return { provider = "native", tab_name = tab_name, success = false, error = err }
  end

  -- Find a suitable main editor window
  local target_win = M._find_main_editor_window()

  if target_win then
    -- Use the main editor window for the diff
    vim.api.nvim_set_current_win(target_win)
  else
    -- Fallback: Create a new window in suitable location
    -- Try to move to a better position
    vim.cmd("wincmd t") -- Go to top-left
    vim.cmd("wincmd l") -- Move right (to middle if layout is left|middle|right)

    -- If we're still in a special window, create a new split
    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")

    if buftype == "terminal" or buftype == "nofile" then
      vim.cmd("vsplit")
    end
  end

  -- Create proper side-by-side diff layout in the selected window
  -- Set up left window with old content (readonly)
  vim.cmd("edit " .. vim.fn.fnameescape(old_file_path))
  vim.cmd("diffthis")

  -- Create vertical split for new content
  vim.cmd("vsplit")
  vim.cmd("edit " .. vim.fn.fnameescape(tmp_file))
  vim.api.nvim_buf_set_name(0, new_file_path .. " (New)")

  -- Make windows equal width
  vim.cmd("wincmd =")

  local new_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = new_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = new_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = new_buf })

  vim.cmd("diffthis")

  local cleanup_group = vim.api.nvim_create_augroup("ClaudeCodeDiffCleanup", { clear = false })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = cleanup_group,
    buffer = new_buf,
    callback = function()
      M._cleanup_temp_file(tmp_file)
    end,
    once = true,
  })

  return {
    provider = "native",
    tab_name = tab_name,
    success = true,
    temp_file = tmp_file,
  }
end

--- Create a scratch buffer for new content
-- @param content string The content to put in the buffer
-- @param filename string The filename for the buffer
-- @return number The buffer ID
function M._create_new_content_buffer(content, filename)
  local buf = vim.api.nvim_create_buf(false, true) -- unlisted, scratch
  if buf == 0 then
    error({
      code = -32000,
      message = "Buffer creation failed",
      data = "Could not create buffer - may be out of memory",
    })
  end

  vim.api.nvim_buf_set_name(buf, filename)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, "\n"))
  return buf
end

--- Safe file reading with error handling
-- @param file_path string Path to the file to read
-- @return string The file content
function M._safe_file_read(file_path)
  local file, err = io.open(file_path, "r")
  if not file then
    error({
      code = -32000,
      message = "File access error",
      data = "Cannot open file: " .. file_path .. " (" .. (err or "unknown error") .. ")",
    })
  end

  local content = file:read("*all")
  file:close()
  return content
end

--- Register diff state for tracking
-- @param tab_name string Unique identifier for the diff
-- @param diff_data table Diff state data
function M._register_diff_state(tab_name, diff_data)
  active_diffs[tab_name] = diff_data
end

--- Find diff by buffer ID
-- @param buffer_id number Buffer ID to search for
-- @return string|nil The tab_name if found
function M._find_diff_by_buffer(buffer_id)
  for tab_name, diff_data in pairs(active_diffs) do
    if diff_data.new_buffer == buffer_id or diff_data.old_buffer == buffer_id then
      return tab_name
    end
  end
  return nil
end

--- Resolve diff as saved (user accepted changes)
-- @param tab_name string The diff identifier
-- @param buffer_id number The buffer that was saved
function M._resolve_diff_as_saved(tab_name, buffer_id)
  local diff_data = active_diffs[tab_name]
  if not diff_data or diff_data.status ~= "pending" then
    return
  end

  -- Get final file contents
  local final_content = table.concat(vim.api.nvim_buf_get_lines(buffer_id, 0, -1, false), "\n")

  -- Write the accepted changes to the actual file
  M._apply_accepted_changes(diff_data, final_content)

  -- Create MCP-compliant response
  local result = {
    content = {
      { type = "text", text = "FILE_SAVED" },
      { type = "text", text = final_content },
    },
  }

  diff_data.status = "saved"
  diff_data.result_content = result

  -- Resume the coroutine with the result (for deferred response system)
  if diff_data.resolution_callback then
    require("claudecode.logger").debug("diff", "Resuming coroutine for saved diff", tab_name)
    -- The resolution_callback is actually coroutine.resume(co, result)
    diff_data.resolution_callback(result)
  else
    require("claudecode.logger").debug("diff", "No resolution callback found for saved diff", tab_name)
  end

  -- NOTE: We do NOT clean up the diff state here - that will be done by close_tab
  require("claudecode.logger").debug("diff", "Diff saved but not closed - waiting for close_tab command")
end

--- Apply accepted changes to the original file and reload open buffers
-- @param diff_data table The diff state data
-- @param final_content string The final content to write
function M._apply_accepted_changes(diff_data, final_content)
  local old_file_path = diff_data.old_file_path
  if not old_file_path then
    require("claudecode.logger").error("diff", "No old_file_path found in diff_data")
    return
  end

  require("claudecode.logger").debug("diff", "Writing accepted changes to file:", old_file_path)

  -- Ensure parent directories exist for new files
  if diff_data.is_new_file then
    local parent_dir = vim.fn.fnamemodify(old_file_path, ":h")
    if parent_dir and parent_dir ~= "" and parent_dir ~= "." then
      require("claudecode.logger").debug("diff", "Creating parent directories for new file:", parent_dir)
      local mkdir_success, mkdir_err = pcall(vim.fn.mkdir, parent_dir, "p")
      if not mkdir_success then
        require("claudecode.logger").error(
          "diff",
          "Failed to create parent directories:",
          parent_dir,
          "error:",
          mkdir_err
        )
        return
      end
      require("claudecode.logger").debug("diff", "Successfully created parent directories:", parent_dir)
    end
  end

  -- Write the content to the actual file
  local lines = vim.split(final_content, "\n")
  local success, err = pcall(vim.fn.writefile, lines, old_file_path)

  if not success then
    require("claudecode.logger").error("diff", "Failed to write file:", old_file_path, "error:", err)
    return
  end

  require("claudecode.logger").debug("diff", "Successfully wrote changes to", old_file_path)

  -- Find and reload any open buffers for this file
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name == old_file_path then
        require("claudecode.logger").debug("diff", "Reloading buffer", buf, "for file:", old_file_path)
        -- Use :edit to reload the buffer
        -- We need to execute this in the context of the buffer
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("edit")
        end)
        require("claudecode.logger").debug("diff", "Successfully reloaded buffer", buf)
      end
    end
  end
end

--- Resolve diff as accepted with final content
-- @param tab_name string The diff identifier
-- @param final_content string The final content after user edits
function M._resolve_diff_as_accepted(tab_name, final_content)
  local diff_data = active_diffs[tab_name]
  if not diff_data or diff_data.status ~= "pending" then
    return
  end

  -- Create MCP-compliant response
  local result = {
    content = {
      { type = "text", text = "FILE_SAVED" },
      { type = "text", text = final_content },
    },
  }

  diff_data.status = "saved"
  diff_data.result_content = result

  -- Write the accepted changes to the actual file and reload any open buffers FIRST
  -- This ensures the file is updated before we send the response
  M._apply_accepted_changes(diff_data, final_content)

  -- Clean up diff state and resources BEFORE resolving to prevent any interference
  M._cleanup_diff_state(tab_name, "changes accepted")

  -- Use vim.schedule to ensure the resolution callback happens after all cleanup
  vim.schedule(function()
    -- Resume the coroutine with the result (for deferred response system)
    if diff_data.resolution_callback then
      require("claudecode.logger").debug("diff", "Resuming coroutine for accepted diff", tab_name)
      diff_data.resolution_callback(result)
    else
      require("claudecode.logger").debug("diff", "No resolution callback found for accepted diff", tab_name)
    end
  end)
end

--- Resolve diff as rejected (user closed/rejected)
-- @param tab_name string The diff identifier
function M._resolve_diff_as_rejected(tab_name)
  local diff_data = active_diffs[tab_name]
  if not diff_data or diff_data.status ~= "pending" then
    return
  end

  -- Create MCP-compliant response
  local result = {
    content = {
      { type = "text", text = "DIFF_REJECTED" },
      { type = "text", text = tab_name },
    },
  }

  diff_data.status = "rejected"
  diff_data.result_content = result

  -- Clean up diff state and resources BEFORE resolving to prevent any interference
  M._cleanup_diff_state(tab_name, "diff rejected")

  -- Use vim.schedule to ensure the resolution callback happens after all cleanup
  vim.schedule(function()
    -- Resume the coroutine with the result (for deferred response system)
    if diff_data.resolution_callback then
      require("claudecode.logger").debug("diff", "Resuming coroutine for rejected diff", tab_name)
      -- The resolution_callback is actually coroutine.resume(co, result)
      diff_data.resolution_callback(result)
    else
      require("claudecode.logger").debug("diff", "No resolution callback found for rejected diff", tab_name)
    end
  end)
end

--- Register autocmds for a specific diff
-- @param tab_name string The diff identifier
-- @param new_buffer number New file buffer ID
-- @param old_buffer number Old file buffer ID
-- @return table List of autocmd IDs
function M._register_diff_autocmds(tab_name, new_buffer, old_buffer)
  local autocmd_ids = {}

  -- Save event monitoring for new buffer (BufWritePost)
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufWritePost", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      require("claudecode.logger").debug("diff", "BufWritePost triggered - accepting diff changes for", tab_name)
      M._resolve_diff_as_saved(tab_name, new_buffer)
    end,
  })

  -- Also handle :w command directly (BufWriteCmd) for immediate acceptance
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      require("claudecode.logger").debug("diff", "BufWriteCmd (:w) triggered - accepting diff changes for", tab_name)
      M._resolve_diff_as_saved(tab_name, new_buffer)
    end,
  })

  -- Buffer deletion monitoring for rejection (multiple events to catch all deletion methods)

  -- BufDelete: When buffer is deleted with :bdelete, :bwipeout, etc.
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufDelete", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      require("claudecode.logger").debug("diff", "BufDelete triggered for new buffer", new_buffer, "tab:", tab_name)
      M._resolve_diff_as_rejected(tab_name)
    end,
  })

  -- BufUnload: When buffer is unloaded (covers more scenarios)
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufUnload", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      require("claudecode.logger").debug("diff", "BufUnload triggered for new buffer", new_buffer, "tab:", tab_name)
      M._resolve_diff_as_rejected(tab_name)
    end,
  })

  -- BufWipeout: When buffer is wiped out completely
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufWipeout", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      require("claudecode.logger").debug("diff", "BufWipeout triggered for new buffer", new_buffer, "tab:", tab_name)
      M._resolve_diff_as_rejected(tab_name)
    end,
  })

  -- Note: We intentionally do NOT monitor old_buffer for deletion
  -- because it's the actual file buffer and shouldn't trigger diff rejection

  return autocmd_ids
end

--- Create diff view from a specific window
-- @param target_window number The window to use as base for the diff
-- @param old_file_path string Path to the original file
-- @param new_buffer number New file buffer ID
-- @param tab_name string The diff identifier
-- @param is_new_file boolean Whether this is a new file (doesn't exist yet)
-- @return table Info about the created diff layout
function M._create_diff_view_from_window(target_window, old_file_path, new_buffer, tab_name, is_new_file)
  require("claudecode.logger").debug("diff", "Creating diff view from window", target_window)

  -- If no target window provided, create a new window in suitable location
  if not target_window then
    -- Try to create a new window in the main area
    vim.cmd("wincmd t") -- Go to top-left
    vim.cmd("wincmd l") -- Move right (to middle if layout is left|middle|right)

    -- Check if we're in a suitable window now
    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
    local filetype = vim.api.nvim_buf_get_option(buf, "filetype")

    if buftype == "terminal" or buftype == "prompt" or filetype == "neo-tree" or filetype == "ClaudeCode" then
      -- Still in a special window, create a new split
      vim.cmd("vsplit")
    end

    target_window = vim.api.nvim_get_current_win()
    require("claudecode.logger").debug("diff", "Created new window for diff", target_window)
  else
    -- Switch to the target window
    vim.api.nvim_set_current_win(target_window)
  end

  -- Handle the left side of the diff (original file or empty for new files)
  local original_buffer
  if is_new_file then
    -- Create an empty buffer for new file comparison
    require("claudecode.logger").debug("diff", "Creating empty buffer for new file diff")
    local empty_buffer = vim.api.nvim_create_buf(false, true) -- unlisted, scratch
    vim.api.nvim_buf_set_name(empty_buffer, old_file_path .. " (NEW FILE)")
    vim.api.nvim_buf_set_lines(empty_buffer, 0, -1, false, {}) -- Empty content
    vim.api.nvim_buf_set_option(empty_buffer, "buftype", "nofile")
    vim.api.nvim_buf_set_option(empty_buffer, "modifiable", false)
    vim.api.nvim_buf_set_option(empty_buffer, "readonly", true)

    vim.api.nvim_win_set_buf(target_window, empty_buffer)
    original_buffer = empty_buffer
  else
    -- Make sure the window shows the existing file we want to diff
    vim.cmd("edit " .. vim.fn.fnameescape(old_file_path))
    original_buffer = vim.api.nvim_win_get_buf(target_window)
  end

  -- Enable diff mode on the original/empty file
  vim.cmd("diffthis")
  require("claudecode.logger").debug(
    "diff",
    "Enabled diff mode on",
    is_new_file and "empty buffer" or "original file",
    "in window",
    target_window
  )

  -- Create vertical split for new buffer (proposed changes)
  vim.cmd("vsplit")
  local new_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(new_win, new_buffer)
  vim.cmd("diffthis")
  require("claudecode.logger").debug("diff", "Created split window", new_win, "with new buffer", new_buffer)

  -- Make windows equal width
  vim.cmd("wincmd =")

  -- Focus on the new window (right side with proposed changes)
  vim.api.nvim_set_current_win(new_win)

  require("claudecode.logger").debug(
    "diff",
    "Diff view setup complete - original window:",
    target_window,
    "new window:",
    new_win
  )

  -- Add helpful keymaps to the new buffer
  local keymap_opts = { buffer = new_buffer, silent = true }

  vim.keymap.set("n", "<leader>da", function()
    -- Accept all changes
    local new_content = vim.api.nvim_buf_get_lines(new_buffer, 0, -1, false)

    -- Ensure parent directories exist for new files
    if is_new_file then
      local parent_dir = vim.fn.fnamemodify(old_file_path, ":h")
      if parent_dir and parent_dir ~= "" and parent_dir ~= "." then
        vim.fn.mkdir(parent_dir, "p")
      end
    end

    -- Write to file
    vim.fn.writefile(new_content, old_file_path)

    -- Close the diff window
    if vim.api.nvim_win_is_valid(new_win) then
      vim.api.nvim_win_close(new_win, true)
    end

    -- Turn off diff mode in original window
    if vim.api.nvim_win_is_valid(target_window) then
      vim.api.nvim_set_current_win(target_window)
      vim.cmd("diffoff")
      -- Reload the file to show the changes
      vim.cmd("edit!")
    end

    M._resolve_diff_as_saved(tab_name, new_buffer)
  end, keymap_opts)

  vim.keymap.set("n", "<leader>dq", function()
    -- Reject changes
    -- Close the diff window
    if vim.api.nvim_win_is_valid(new_win) then
      vim.api.nvim_win_close(new_win, true)
    end

    -- Turn off diff mode in original window
    if vim.api.nvim_win_is_valid(target_window) then
      vim.api.nvim_set_current_win(target_window)
      vim.cmd("diffoff")
    end

    M._resolve_diff_as_rejected(tab_name)
  end, keymap_opts)

  -- Return window information for later storage
  return {
    new_window = new_win,
    target_window = target_window,
    original_buffer = original_buffer,
  }
end

--- Clean up diff state and resources
-- @param tab_name string The diff identifier
-- @param reason string Reason for cleanup
function M._cleanup_diff_state(tab_name, reason)
  local diff_data = active_diffs[tab_name]
  if not diff_data then
    return
  end

  -- Clean up autocmds
  for _, autocmd_id in ipairs(diff_data.autocmd_ids or {}) do
    pcall(vim.api.nvim_del_autocmd, autocmd_id)
  end

  -- Clean up the new buffer only (not the old buffer which is the user's file)
  if diff_data.new_buffer and vim.api.nvim_buf_is_valid(diff_data.new_buffer) then
    pcall(vim.api.nvim_buf_delete, diff_data.new_buffer, { force = true })
  end

  -- Close new diff window if still open
  if diff_data.new_window and vim.api.nvim_win_is_valid(diff_data.new_window) then
    pcall(vim.api.nvim_win_close, diff_data.new_window, true)
  end

  -- Turn off diff mode in target window if it still exists
  if diff_data.target_window and vim.api.nvim_win_is_valid(diff_data.target_window) then
    vim.api.nvim_win_call(diff_data.target_window, function()
      vim.cmd("diffoff")
    end)
  end

  -- Remove from active diffs
  active_diffs[tab_name] = nil

  -- Log cleanup reason
  require("claudecode.logger").debug("Cleaned up diff state for '" .. tab_name .. "' due to: " .. reason)
end

--- Clean up all active diffs
-- @param reason string Reason for cleanup
function M._cleanup_all_active_diffs(reason)
  for tab_name, _ in pairs(active_diffs) do
    M._cleanup_diff_state(tab_name, reason)
  end
end

--- Set up blocking diff operation with simpler approach
-- @param params table Parameters for the diff
-- @param resolution_callback function Callback to call when diff resolves
function M._setup_blocking_diff(params, resolution_callback)
  local tab_name = params.tab_name
  require("claudecode.logger").debug(
    "diff",
    "Setup step 1: Finding existing buffer or window for",
    params.old_file_path
  )

  -- Step 1: Check if the file exists (allow new files)
  local old_file_exists = vim.fn.filereadable(params.old_file_path) == 1
  local is_new_file = not old_file_exists

  require("claudecode.logger").debug(
    "diff",
    "File existence check - old_file_exists:",
    old_file_exists,
    "is_new_file:",
    is_new_file,
    "path:",
    params.old_file_path
  )

  -- Step 2: Find if the file is already open in a buffer (only for existing files)
  local existing_buffer = nil
  local target_window = nil

  if old_file_exists then
    -- Look for existing buffer with this file
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        local buf_name = vim.api.nvim_buf_get_name(buf)
        if buf_name == params.old_file_path then
          existing_buffer = buf
          require("claudecode.logger").debug("diff", "Found existing buffer", buf, "for file", params.old_file_path)
          break
        end
      end
    end

    -- Find window containing this buffer (if any)
    if existing_buffer then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == existing_buffer then
          target_window = win
          require("claudecode.logger").debug("diff", "Found window", win, "containing buffer", existing_buffer)
          break
        end
      end
    end
  else
    require("claudecode.logger").debug("diff", "Skipping buffer search for new file:", params.old_file_path)
  end

  -- If no existing buffer/window, find a suitable main editor window
  if not target_window then
    target_window = M._find_main_editor_window()
    if target_window then
      require("claudecode.logger").debug(
        "diff",
        "No existing buffer/window found, using main editor window",
        target_window
      )
    else
      -- Fallback: Create a new window
      require("claudecode.logger").debug("diff", "No suitable window found, will create new window")
      -- This will be handled in _create_diff_view_from_window
    end
  end

  -- Step 3: Create scratch buffer for new content
  require("claudecode.logger").debug("diff", "Creating new content buffer")
  local new_buffer = vim.api.nvim_create_buf(false, true) -- unlisted, scratch
  if new_buffer == 0 then
    error({
      code = -32000,
      message = "Buffer creation failed",
      data = "Could not create new content buffer",
    })
  end

  local new_unique_name = is_new_file and (tab_name .. " (NEW FILE - proposed)") or (tab_name .. " (proposed)")
  vim.api.nvim_buf_set_name(new_buffer, new_unique_name)
  vim.api.nvim_buf_set_lines(new_buffer, 0, -1, false, vim.split(params.new_file_contents, "\n"))

  vim.api.nvim_buf_set_option(new_buffer, "buftype", "acwrite") -- Allows saving but stays as scratch-like
  vim.api.nvim_buf_set_option(new_buffer, "modifiable", true)

  -- Step 4: Set up diff view using the target window
  require("claudecode.logger").debug(
    "diff",
    "Creating diff view from window",
    target_window,
    "is_new_file:",
    is_new_file
  )
  local diff_info =
    M._create_diff_view_from_window(target_window, params.old_file_path, new_buffer, tab_name, is_new_file)

  -- Step 5: Register autocmds for user interaction monitoring
  require("claudecode.logger").debug("diff", "Registering autocmds")
  local autocmd_ids = M._register_diff_autocmds(tab_name, new_buffer, nil)

  -- Step 6: Store diff state
  require("claudecode.logger").debug("diff", "Storing diff state")
  M._register_diff_state(tab_name, {
    old_file_path = params.old_file_path,
    new_file_path = params.new_file_path,
    new_file_contents = params.new_file_contents,
    new_buffer = new_buffer,
    new_window = diff_info.new_window,
    target_window = diff_info.target_window,
    original_buffer = diff_info.original_buffer,
    autocmd_ids = autocmd_ids,
    created_at = vim.fn.localtime(),
    status = "pending",
    resolution_callback = resolution_callback,
    result_content = nil,
    is_new_file = is_new_file,
  })
  require("claudecode.logger").debug("diff", "Setup completed successfully for", tab_name)
end

--- Blocking diff operation for MCP compliance
-- @param old_file_path string Path to the original file
-- @param new_file_path string Path to the new file (used for naming)
-- @param new_file_contents string Contents of the new file
-- @param tab_name string Name for the diff tab/view
-- @return table MCP-compliant response with content array
function M.open_diff_blocking(old_file_path, new_file_path, new_file_contents, tab_name)
  -- Check for existing diff with same tab_name
  if active_diffs[tab_name] then
    -- Resolve the existing diff as rejected before replacing
    M._resolve_diff_as_rejected(tab_name)
  end

  -- Set up blocking diff operation
  local co = coroutine.running()
  if not co then
    error({
      code = -32000,
      message = "Internal server error",
      data = "openDiff must run in coroutine context",
    })
  end

  -- Initialize diff state and monitoring
  require("claudecode.logger").debug("diff", "Starting diff setup for tab_name:", tab_name)

  -- Use native diff implementation
  local success, err = pcall(M._setup_blocking_diff, {
    old_file_path = old_file_path,
    new_file_path = new_file_path,
    new_file_contents = new_file_contents,
    tab_name = tab_name,
  }, function(result)
    -- Resume the coroutine with the result
    require("claudecode.logger").debug("diff", "Resolution callback called for coroutine:", tostring(co))
    local resume_success, resume_result = coroutine.resume(co, result)
    if resume_success then
      -- Coroutine completed successfully - send the response using the global sender
      require("claudecode.logger").debug(
        "diff",
        "Coroutine completed successfully with result:",
        vim.inspect(resume_result)
      )

      -- Use the global response sender to avoid module reloading issues
      local co_key = tostring(co)
      if _G.claude_deferred_responses and _G.claude_deferred_responses[co_key] then
        require("claudecode.logger").debug("diff", "Calling global response sender for coroutine:", co_key)
        _G.claude_deferred_responses[co_key](resume_result)
        -- Clean up
        _G.claude_deferred_responses[co_key] = nil
      else
        require("claudecode.logger").error("diff", "No global response sender found for coroutine:", co_key)
      end
    else
      -- Coroutine failed - send error response
      require("claudecode.logger").error("diff", "Coroutine failed:", tostring(resume_result))
      local co_key = tostring(co)
      if _G.claude_deferred_responses and _G.claude_deferred_responses[co_key] then
        _G.claude_deferred_responses[co_key]({
          error = {
            code = -32603,
            message = "Internal error",
            data = "Coroutine failed: " .. tostring(resume_result),
          },
        })
        -- Clean up
        _G.claude_deferred_responses[co_key] = nil
      end
    end
  end)

  if not success then
    require("claudecode.logger").error("diff", "Diff setup failed for", tab_name, "error:", vim.inspect(err))
    -- If the error is already structured, propagate it directly
    if type(err) == "table" and err.code then
      error(err)
    else
      error({
        code = -32000,
        message = "Error setting up diff",
        data = tostring(err),
      })
    end
  end

  require("claudecode.logger").debug(
    "diff",
    "Diff setup completed successfully for",
    tab_name,
    "- about to yield and wait for user action"
  )

  -- Yield and wait indefinitely for user interaction - the resolve functions will resume us
  require("claudecode.logger").debug("diff", "About to yield and wait for user action")
  local user_action_result = coroutine.yield()
  require("claudecode.logger").debug("diff", "User interaction detected, got result:", vim.inspect(user_action_result))

  -- Return the result directly - this will be sent by the deferred response system
  return user_action_result
end

-- Set up global autocmds for shutdown handling
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = get_autocmd_group(),
  callback = function()
    M._cleanup_all_active_diffs("shutdown")
  end,
})

--- Close diff by tab name (used by close_tab tool)
-- @param tab_name string The diff identifier
-- @return boolean success True if diff was found and closed
function M.close_diff_by_tab_name(tab_name)
  local diff_data = active_diffs[tab_name]
  if not diff_data then
    return false
  end

  -- If the diff was already saved, just clean up
  if diff_data.status == "saved" then
    M._cleanup_diff_state(tab_name, "diff tab closed after save")
    return true
  end

  -- If still pending, treat as rejection
  if diff_data.status == "pending" then
    M._resolve_diff_as_rejected(tab_name)
    return true
  end

  return false
end

-- Test helper function (only for testing)
function M._get_active_diffs()
  return active_diffs
end

return M
