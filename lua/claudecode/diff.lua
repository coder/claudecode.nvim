--- Diff module for Claude Code Neovim integration.
-- Provides native Neovim diff functionality with MCP-compliant blocking operations and state management.
local M = {}

local logger = require("claudecode.logger")

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
local function find_main_editor_window()
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
        or filetype == "oil"
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
local function create_temp_file(content, filename)
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
local function cleanup_temp_file(tmp_file)
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

-- Detect filetype from a path or existing buffer (best-effort)
local function detect_filetype(path, buf)
  -- 1) Try Neovim's builtin matcher if available (>=0.10)
  if vim.filetype and type(vim.filetype.match) == "function" then
    local ok, ft = pcall(vim.filetype.match, { filename = path })
    if ok and ft and ft ~= "" then
      return ft
    end
  end

  -- 2) Try reading from existing buffer
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local ft = vim.api.nvim_buf_get_option(buf, "filetype")
    if ft and ft ~= "" then
      return ft
    end
  end

  -- 3) Fallback to simple extension mapping
  local ext = path:match("%.([%w_%-]+)$") or ""
  local simple_map = {
    lua = "lua",
    ts = "typescript",
    js = "javascript",
    jsx = "javascriptreact",
    tsx = "typescriptreact",
    py = "python",
    go = "go",
    rs = "rust",
    c = "c",
    h = "c",
    cpp = "cpp",
    hpp = "cpp",
    md = "markdown",
    sh = "sh",
    zsh = "zsh",
    bash = "bash",
    json = "json",
    yaml = "yaml",
    yml = "yaml",
    toml = "toml",
  }
  return simple_map[ext]
end
--- Open diff using native Neovim functionality
-- @param old_file_path string Path to the original file
-- @param new_file_path string Path to the new file (used for naming)
-- @param new_file_contents string Contents of the new file
-- @param tab_name string Name for the diff tab/view
-- @return table Result with provider, tab_name, and success status
function M._open_native_diff(old_file_path, new_file_path, new_file_contents, tab_name)
  local new_filename = vim.fn.fnamemodify(new_file_path, ":t") .. ".new"
  local tmp_file, err = create_temp_file(new_file_contents, new_filename)
  if not tmp_file then
    return { provider = "native", tab_name = tab_name, success = false, error = err, temp_file = nil }
  end

  local target_win = find_main_editor_window()

  if target_win then
    vim.api.nvim_set_current_win(target_win)
  else
    vim.cmd("wincmd t")
    vim.cmd("wincmd l")
    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")

    if buftype == "terminal" or buftype == "nofile" then
      vim.cmd("vsplit")
    end
  end

  vim.cmd("edit " .. vim.fn.fnameescape(old_file_path))
  vim.cmd("diffthis")
  vim.cmd("vsplit")
  vim.cmd("edit " .. vim.fn.fnameescape(tmp_file))
  vim.api.nvim_buf_set_name(0, new_file_path .. " (New)")

  -- Propagate filetype to the proposed buffer for proper syntax highlighting (#20)
  local proposed_buf = vim.api.nvim_get_current_buf()
  local old_filetype = detect_filetype(old_file_path)
  if old_filetype and old_filetype ~= "" then
    vim.api.nvim_set_option_value("filetype", old_filetype, { buf = proposed_buf })
  end

  vim.cmd("wincmd =")

  local new_buf = proposed_buf
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = new_buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = new_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = new_buf })

  vim.cmd("diffthis")

  local cleanup_group = vim.api.nvim_create_augroup("ClaudeCodeDiffCleanup", { clear = false })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = cleanup_group,
    buffer = new_buf,
    callback = function()
      cleanup_temp_file(tmp_file)
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

--- Register diff state for tracking
-- @param tab_name string Unique identifier for the diff
-- @param diff_data table Diff state data
function M._register_diff_state(tab_name, diff_data)
  active_diffs[tab_name] = diff_data
end

--- Resolve diff as saved (user accepted changes)
-- @param tab_name string The diff identifier
-- @param buffer_id number The buffer that was saved
function M._resolve_diff_as_saved(tab_name, buffer_id)
  local diff_data = active_diffs[tab_name]
  if not diff_data or diff_data.status ~= "pending" then
    return
  end

  logger.debug("diff", "Resolving diff as saved for", tab_name, "from buffer", buffer_id)

  -- Get content from buffer
  local content_lines = vim.api.nvim_buf_get_lines(buffer_id, 0, -1, false)
  local final_content = table.concat(content_lines, "\n")
  -- Add trailing newline if the buffer has one
  if #content_lines > 0 and vim.api.nvim_buf_get_option(buffer_id, "eol") then
    final_content = final_content .. "\n"
  end

  -- Close diff windows (unified behavior)
  if diff_data.new_window and vim.api.nvim_win_is_valid(diff_data.new_window) then
    vim.api.nvim_win_close(diff_data.new_window, true)
  end
  if diff_data.target_window and vim.api.nvim_win_is_valid(diff_data.target_window) then
    vim.api.nvim_set_current_win(diff_data.target_window)
    vim.cmd("diffoff")
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

  -- Resume the coroutine with the result (for deferred response system)
  if diff_data.resolution_callback then
    logger.debug("diff", "Resuming coroutine for saved diff", tab_name)
    diff_data.resolution_callback(result)
  else
    logger.debug("diff", "No resolution callback found for saved diff", tab_name)
  end

  -- Reload the original file buffer after a delay to ensure Claude CLI has written the file
  vim.defer_fn(function()
    local current_diff_data = active_diffs[tab_name]
    local original_cursor_pos = current_diff_data and current_diff_data.original_cursor_pos
    M.reload_file_buffers_manual(diff_data.old_file_path, original_cursor_pos)
  end, 200)

  -- NOTE: Diff state cleanup is handled by close_tab tool or explicit cleanup calls
  logger.debug("diff", "Diff saved, awaiting close_tab command for cleanup")
end

--- Reload file buffers after external changes (called when diff is closed)
-- @param file_path string Path to the file that was externally modified
-- @param original_cursor_pos table|nil Original cursor position to restore {row, col}
local function reload_file_buffers(file_path, original_cursor_pos)
  logger.debug("diff", "Reloading buffers for file:", file_path, original_cursor_pos and "(restoring cursor)" or "")

  local reloaded_count = 0
  -- Find and reload any open buffers for this file
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)

      -- Simple string match - if buffer name matches the file path
      if buf_name == file_path then
        -- Check if buffer is modified - only reload unmodified buffers for safety
        local modified = vim.api.nvim_buf_get_option(buf, "modified")
        logger.debug("diff", "Found matching buffer", buf, "modified:", modified)

        if not modified then
          -- Try to find a window displaying this buffer for proper context
          local win_id = nil
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == buf then
              win_id = win
              break
            end
          end

          if win_id then
            vim.api.nvim_win_call(win_id, function()
              vim.cmd("edit")
              -- Restore original cursor position if we have it
              if original_cursor_pos then
                pcall(vim.api.nvim_win_set_cursor, win_id, original_cursor_pos)
              end
            end)
          else
            vim.api.nvim_buf_call(buf, function()
              vim.cmd("edit")
            end)
          end

          reloaded_count = reloaded_count + 1
        end
      end
    end
  end

  logger.debug("diff", "Completed buffer reload - reloaded", reloaded_count, "buffers for file:", file_path)
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
      logger.debug("diff", "Resuming coroutine for rejected diff", tab_name)
      diff_data.resolution_callback(result)
    end
  end)
end

--- Register autocmds for a specific diff
-- @param tab_name string The diff identifier
-- @param new_buffer number New file buffer ID
-- @return table List of autocmd IDs
local function register_diff_autocmds(tab_name, new_buffer)
  local autocmd_ids = {}

  -- Handle :w command to accept diff changes (replaces both BufWritePost and BufWriteCmd)
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      logger.debug("diff", "BufWriteCmd (:w) triggered - accepting diff changes for", tab_name)
      M._resolve_diff_as_saved(tab_name, new_buffer)
      -- Prevent actual file write since we're handling it through MCP
      return true
    end,
  })

  -- Buffer deletion monitoring for rejection (multiple events to catch all deletion methods)

  -- BufDelete: When buffer is deleted with :bdelete, :bwipeout, etc.
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufDelete", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      logger.debug("diff", "BufDelete triggered for new buffer", new_buffer, "tab:", tab_name)
      M._resolve_diff_as_rejected(tab_name)
    end,
  })

  -- BufUnload: When buffer is unloaded (covers more scenarios)
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufUnload", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      logger.debug("diff", "BufUnload triggered for new buffer", new_buffer, "tab:", tab_name)
      M._resolve_diff_as_rejected(tab_name)
    end,
  })

  -- BufWipeout: When buffer is wiped out completely
  autocmd_ids[#autocmd_ids + 1] = vim.api.nvim_create_autocmd("BufWipeout", {
    group = get_autocmd_group(),
    buffer = new_buffer,
    callback = function()
      logger.debug("diff", "BufWipeout triggered for new buffer", new_buffer, "tab:", tab_name)
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
  -- If no target window provided, create a new window in suitable location
  if not target_window then
    -- Try to create a new window in the main area
    vim.cmd("wincmd t") -- Go to top-left
    vim.cmd("wincmd l") -- Move right (to middle if layout is left|middle|right)

    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
    local filetype = vim.api.nvim_buf_get_option(buf, "filetype")

    if buftype == "terminal" or buftype == "prompt" or filetype == "neo-tree" or filetype == "ClaudeCode" then
      vim.cmd("vsplit")
    end

    target_window = vim.api.nvim_get_current_win()
  else
    vim.api.nvim_set_current_win(target_window)
  end

  local original_buffer
  if is_new_file then
    local empty_buffer = vim.api.nvim_create_buf(false, true)
    if not empty_buffer or empty_buffer == 0 then
      local error_msg = "Failed to create empty buffer for new file diff"
      logger.error("diff", error_msg)
      error({
        code = -32000,
        message = "Buffer creation failed",
        data = error_msg,
      })
    end

    -- Set buffer properties with error handling
    local success, err = pcall(function()
      vim.api.nvim_buf_set_name(empty_buffer, old_file_path .. " (NEW FILE)")
      vim.api.nvim_buf_set_lines(empty_buffer, 0, -1, false, {})
      vim.api.nvim_buf_set_option(empty_buffer, "buftype", "nofile")
      vim.api.nvim_buf_set_option(empty_buffer, "modifiable", false)
      vim.api.nvim_buf_set_option(empty_buffer, "readonly", true)
    end)

    if not success then
      pcall(vim.api.nvim_buf_delete, empty_buffer, { force = true })
      local error_msg = "Failed to configure empty buffer: " .. tostring(err)
      logger.error("diff", error_msg)
      error({
        code = -32000,
        message = "Buffer configuration failed",
        data = error_msg,
      })
    end

    vim.api.nvim_win_set_buf(target_window, empty_buffer)
    original_buffer = empty_buffer
  else
    vim.cmd("edit " .. vim.fn.fnameescape(old_file_path))
    original_buffer = vim.api.nvim_win_get_buf(target_window)
  end

  vim.cmd("diffthis")

  vim.cmd("vsplit")
  local new_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(new_win, new_buffer)

  -- Ensure new buffer inherits filetype from original for syntax highlighting (#20)
  local original_ft = detect_filetype(old_file_path, original_buffer)
  if original_ft and original_ft ~= "" then
    vim.api.nvim_set_option_value("filetype", original_ft, { buf = new_buffer })
  end
  vim.cmd("diffthis")

  vim.cmd("wincmd =")
  vim.api.nvim_set_current_win(new_win)

  -- Store diff context in buffer variables for user commands
  vim.b[new_buffer].claudecode_diff_tab_name = tab_name
  vim.b[new_buffer].claudecode_diff_new_win = new_win
  vim.b[new_buffer].claudecode_diff_target_win = target_window

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

  logger.debug("diff", "Cleaned up diff state for", tab_name, "due to:", reason)
end

--- Clean up all active diffs
-- @param reason string Reason for cleanup
-- NOTE: This will become a public closeAllDiffTabs tool in the future
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
  logger.debug("diff", "Setting up diff for:", params.old_file_path)

  -- Wrap the setup in error handling to ensure cleanup on failure
  local setup_success, setup_error = pcall(function()
    -- Step 1: Check if the file exists (allow new files)
    local old_file_exists = vim.fn.filereadable(params.old_file_path) == 1
    local is_new_file = not old_file_exists

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
            break
          end
        end
      end

      -- Find window containing this buffer (if any)
      if existing_buffer then
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(win) == existing_buffer then
            target_window = win
            break
          end
        end
      end
    end

    -- If no existing buffer/window, find a suitable main editor window
    if not target_window then
      target_window = find_main_editor_window()
    end

    -- Step 3: Create scratch buffer for new content
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
    local lines = vim.split(params.new_file_contents, "\n")
    -- Remove trailing empty line if content ended with \n
    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines, #lines)
    end
    vim.api.nvim_buf_set_lines(new_buffer, 0, -1, false, lines)

    vim.api.nvim_buf_set_option(new_buffer, "buftype", "acwrite") -- Allows saving but stays as scratch-like
    vim.api.nvim_buf_set_option(new_buffer, "modifiable", true)

    -- Step 4: Set up diff view using the target window
    local diff_info =
      M._create_diff_view_from_window(target_window, params.old_file_path, new_buffer, tab_name, is_new_file)

    -- Step 5: Register autocmds for user interaction monitoring
    local autocmd_ids = register_diff_autocmds(tab_name, new_buffer)

    -- Step 6: Store diff state

    -- Save the original cursor position before storing diff state
    local original_cursor_pos = nil
    if diff_info.target_window and vim.api.nvim_win_is_valid(diff_info.target_window) then
      original_cursor_pos = vim.api.nvim_win_get_cursor(diff_info.target_window)
    end

    M._register_diff_state(tab_name, {
      old_file_path = params.old_file_path,
      new_file_path = params.new_file_path,
      new_file_contents = params.new_file_contents,
      new_buffer = new_buffer,
      new_window = diff_info.new_window,
      target_window = diff_info.target_window,
      original_buffer = diff_info.original_buffer,
      original_cursor_pos = original_cursor_pos,
      autocmd_ids = autocmd_ids,
      created_at = vim.fn.localtime(),
      status = "pending",
      resolution_callback = resolution_callback,
      result_content = nil,
      is_new_file = is_new_file,
    })
  end) -- End of pcall

  -- Handle setup errors
  if not setup_success then
    local error_msg = "Failed to setup diff operation: " .. tostring(setup_error)
    logger.error("diff", error_msg)

    -- Clean up any partial state that might have been created
    if active_diffs[tab_name] then
      M._cleanup_diff_state(tab_name, "setup failed")
    end

    -- Re-throw the error for MCP compliance
    error({
      code = -32000,
      message = "Diff setup failed",
      data = error_msg,
    })
  end
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

  logger.debug("diff", "Starting diff setup for", tab_name)

  -- Use native diff implementation
  local success, err = pcall(M._setup_blocking_diff, {
    old_file_path = old_file_path,
    new_file_path = new_file_path,
    new_file_contents = new_file_contents,
    tab_name = tab_name,
  }, function(result)
    -- Resume the coroutine with the result
    local resume_success, resume_result = coroutine.resume(co, result)
    if resume_success then
      -- Use the global response sender to avoid module reloading issues
      local co_key = tostring(co)
      if _G.claude_deferred_responses and _G.claude_deferred_responses[co_key] then
        _G.claude_deferred_responses[co_key](resume_result)
        _G.claude_deferred_responses[co_key] = nil
      else
        logger.error("diff", "No global response sender found for coroutine:", co_key)
      end
    else
      logger.error("diff", "Coroutine failed:", tostring(resume_result))
      local co_key = tostring(co)
      if _G.claude_deferred_responses and _G.claude_deferred_responses[co_key] then
        _G.claude_deferred_responses[co_key]({
          error = {
            code = -32603,
            message = "Internal error",
            data = "Coroutine failed: " .. tostring(resume_result),
          },
        })
        _G.claude_deferred_responses[co_key] = nil
      end
    end
  end)

  if not success then
    logger.error("diff", "Diff setup failed for", tab_name, "error:", tostring(err))
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

  -- Yield and wait indefinitely for user interaction - the resolve functions will resume us
  local user_action_result = coroutine.yield()
  logger.debug("diff", "User action completed for", tab_name)

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

  -- If the diff was already saved, reload file buffers and clean up
  if diff_data.status == "saved" then
    -- Claude Code CLI has written the file, reload any open buffers
    if diff_data.old_file_path then
      -- Add a small delay to ensure Claude CLI has finished writing the file
      vim.defer_fn(function()
        M.reload_file_buffers_manual(diff_data.old_file_path, diff_data.original_cursor_pos)
      end, 100) -- 100ms delay
    end
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

-- Manual buffer reload function for testing/debugging
function M.reload_file_buffers_manual(file_path, original_cursor_pos)
  return reload_file_buffers(file_path, original_cursor_pos)
end

--- Accept the current diff (user command version)
-- This function reads the diff context from buffer variables
function M.accept_current_diff()
  local current_buffer = vim.api.nvim_get_current_buf()
  local tab_name = vim.b[current_buffer].claudecode_diff_tab_name

  if not tab_name then
    vim.notify("No active diff found in current buffer", vim.log.levels.WARN)
    return
  end

  M._resolve_diff_as_saved(tab_name, current_buffer)
end

--- Deny/reject the current diff (user command version)
-- This function reads the diff context from buffer variables
function M.deny_current_diff()
  local current_buffer = vim.api.nvim_get_current_buf()
  local tab_name = vim.b[current_buffer].claudecode_diff_tab_name
  local new_win = vim.b[current_buffer].claudecode_diff_new_win
  local target_window = vim.b[current_buffer].claudecode_diff_target_win

  if not tab_name then
    vim.notify("No active diff found in current buffer", vim.log.levels.WARN)
    return
  end

  -- Close windows and clean up (same logic as the original keymap)
  if new_win and vim.api.nvim_win_is_valid(new_win) then
    vim.api.nvim_win_close(new_win, true)
  end
  if target_window and vim.api.nvim_win_is_valid(target_window) then
    vim.api.nvim_set_current_win(target_window)
    vim.cmd("diffoff")
  end

  M._resolve_diff_as_rejected(tab_name)
end

return M
