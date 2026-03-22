---Native Neovim terminal provider for OpenCode.
---@module 'opencode.terminal.native'

local M = {}

local logger = require("opencode.logger")
local utils = require("opencode.utils")

local bufnr = nil
local winid = nil
local jobid = nil
local tip_shown = false

---@type OpenCodeTerminalConfig
local config = require("opencode.terminal").defaults

local function cleanup_state()
  bufnr = nil
  winid = nil
  jobid = nil
end

local function is_valid()
  -- First check if we have a valid buffer
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    cleanup_state()
    return false
  end

  -- If buffer is valid but window is invalid, try to find a window displaying this buffer
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    -- Search all windows for our terminal buffer
    local windows = vim.api.nvim_list_wins()
    for _, win in ipairs(windows) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        -- Found a window displaying our terminal buffer, update the tracked window ID
        winid = win
        logger.debug("terminal", "Recovered terminal window ID:", win)
        return true
      end
    end
    -- Buffer exists but no window displays it - this is normal for hidden terminals
    return true -- Buffer is valid even though not visible
  end

  -- Both buffer and window are valid
  return true
end

local function open_terminal(cmd_string, env_table, effective_config, focus)
  focus = utils.normalize_focus(focus)

  if is_valid() then -- Should not happen if called correctly, but as a safeguard
    if focus then
      -- Focus existing terminal: switch to terminal window and enter insert mode
      vim.api.nvim_set_current_win(winid)
      vim.cmd("startinsert")
    end
    -- If focus=false, preserve user context by staying in current window
    return true
  end

  local original_win = vim.api.nvim_get_current_win()
  local width = math.floor(vim.o.columns * effective_config.split_width_percentage)
  local full_height = vim.o.lines
  local placement_modifier

  if effective_config.split_side == "left" then
    placement_modifier = "topleft "
  else
    placement_modifier = "botright "
  end

  vim.cmd(placement_modifier .. width .. "vsplit")
  local new_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(new_winid, full_height)

  vim.api.nvim_win_call(new_winid, function()
    vim.cmd("enew")
  end)

  local term_cmd_arg
  if cmd_string:find(" ", 1, true) then
    term_cmd_arg = vim.split(cmd_string, " ", { plain = true, trimempty = false })
  else
    term_cmd_arg = { cmd_string }
  end

  jobid = vim.fn.termopen(term_cmd_arg, {
    env = env_table,
    cwd = effective_config.cwd,
    on_exit = function(job_id, _, _)
      vim.schedule(function()
        if job_id == jobid then
          logger.debug("terminal", "Terminal process exited, cleaning up")

          -- Kill any remaining child processes to prevent zombies
          if vim.fn.has("unix") == 1 then
            vim.fn.system("pkill -9 -P " .. tostring(job_id) .. " 2>/dev/null || true")
          end

          -- Ensure we are operating on the correct window and buffer before closing
          local current_winid_for_job = winid
          local current_bufnr_for_job = bufnr

          cleanup_state() -- Clear our managed state first

          if not effective_config.auto_close then
            return
          end

          if current_winid_for_job and vim.api.nvim_win_is_valid(current_winid_for_job) then
            if current_bufnr_for_job and vim.api.nvim_buf_is_valid(current_bufnr_for_job) then
              -- Optional: Check if the window still holds the same terminal buffer
              if vim.api.nvim_win_get_buf(current_winid_for_job) == current_bufnr_for_job then
                vim.api.nvim_win_close(current_winid_for_job, true)
              end
            else
              -- Buffer is invalid, but window might still be there (e.g. if user changed buffer in term window)
              -- Still try to close the window we tracked.
              vim.api.nvim_win_close(current_winid_for_job, true)
            end
          end
        end
      end)
    end,
  })

  if not jobid or jobid == 0 then
    vim.notify("Failed to open native terminal.", vim.log.levels.ERROR)
    vim.api.nvim_win_close(new_winid, true)
    vim.api.nvim_set_current_win(original_win)
    cleanup_state()
    return false
  end

  winid = new_winid
  bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].bufhidden = "hide"
  -- buftype=terminal is set by termopen

  if focus then
    -- Focus the terminal: switch to terminal window and enter insert mode
    vim.api.nvim_set_current_win(winid)
    vim.cmd("startinsert")
  else
    -- Preserve user context: return to the window they were in before terminal creation
    vim.api.nvim_set_current_win(original_win)
  end

  if config.show_native_term_exit_tip and not tip_shown then
    vim.notify("Native terminal opened. Press Ctrl-\\ Ctrl-N to return to Normal mode.", vim.log.levels.INFO)
    tip_shown = true
  end
  return true
end

local function close_terminal()
  if is_valid() then
    -- Kill the job process and any children before closing
    if jobid and jobid > 0 then
      -- Try to kill the process group (negative PID on Unix)
      -- This ensures child processes spawned by opencode are also terminated
      pcall(function()
        vim.fn.jobstop(jobid)
      end)
      
      -- On Unix systems, also try to kill the process group
      if vim.fn.has("unix") == 1 then
        vim.fn.system("pkill -9 -P " .. tostring(jobid) .. " 2>/dev/null || true")
      end
      
      -- Give processes a moment to die
      vim.wait(50)
    end
    
    -- Closing the window should trigger on_exit of the job if the process is still running,
    -- which then calls cleanup_state.
    -- If the job already exited, on_exit would have cleaned up.
    -- This direct close is for user-initiated close.
    vim.api.nvim_win_close(winid, true)
    cleanup_state() -- Cleanup after explicit close
  end
end

local function focus_terminal()
  if is_valid() then
    vim.api.nvim_set_current_win(winid)
    vim.cmd("startinsert")
  end
end

local function is_terminal_visible()
  -- Check if our terminal buffer exists and is displayed in any window
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local windows = vim.api.nvim_list_wins()
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      -- Update our tracked window ID if we find the buffer in a different window
      winid = win
      return true
    end
  end

  -- Buffer exists but no window displays it
  winid = nil
  return false
end

local function hide_terminal()
  -- Hide the terminal window but keep the buffer and job alive
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and winid and vim.api.nvim_win_is_valid(winid) then
    -- Close the window - this preserves the buffer and job
    vim.api.nvim_win_close(winid, false)
    winid = nil -- Clear window reference

    logger.debug("terminal", "Terminal window hidden, process preserved")
  end
end

local function show_hidden_terminal(effective_config, focus)
  -- Show an existing hidden terminal buffer in a new window
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  -- Check if it's already visible
  if is_terminal_visible() then
    if focus then
      focus_terminal()
    end
    return true
  end

  local original_win = vim.api.nvim_get_current_win()

  -- Create a new window for the existing buffer
  local width = math.floor(vim.o.columns * effective_config.split_width_percentage)
  local full_height = vim.o.lines
  local placement_modifier

  if effective_config.split_side == "left" then
    placement_modifier = "topleft "
  else
    placement_modifier = "botright "
  end

  vim.cmd(placement_modifier .. width .. "vsplit")
  local new_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(new_winid, full_height)

  -- Set the existing buffer in the new window
  vim.api.nvim_win_set_buf(new_winid, bufnr)
  winid = new_winid

  if focus then
    -- Focus the terminal: switch to terminal window and enter insert mode
    vim.api.nvim_set_current_win(winid)
    vim.cmd("startinsert")
  else
    -- Preserve user context: return to the window they were in before showing terminal
    vim.api.nvim_set_current_win(original_win)
  end

  logger.debug("terminal", "Showed hidden terminal in new window")
  return true
end

local function get_command_hints()
  local hints = {}
  local configured_cmd = (config and config.terminal_cmd) or "opencode"

  for token in configured_cmd:gmatch("%S+") do
    local normalized = token:gsub('^["\']', "")
    normalized = normalized:gsub('["\']$', "")
    normalized = normalized:match("[^/\\]+$") or normalized
    normalized = normalized:lower()

    if normalized ~= "" then
      hints[normalized] = true
      if normalized:find("opencode", 1, true) then
        hints["opencode"] = true
      end
      if normalized:find("claude", 1, true) then
        hints["claude"] = true
      end
    end
  end

  if next(hints) == nil then
    hints["opencode"] = true
  end

  return hints
end

local function find_existing_managed_terminal()
  local hints = get_command_hints()
  local buffers = vim.api.nvim_list_bufs()
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      local lower_name = buf_name:lower()

      for hint in pairs(hints) do
        if lower_name:find(hint, 1, true) then
          local windows = vim.api.nvim_list_wins()
          for _, win in ipairs(windows) do
            if vim.api.nvim_win_get_buf(win) == buf then
              logger.debug("terminal", "Found existing managed terminal in buffer", buf, "window", win)
              return buf, win
            end
          end
          break
        end
      end
    end
  end
  return nil, nil
end

---Setup the terminal module
---@param term_config OpenCodeTerminalConfig
function M.setup(term_config)
  config = term_config
  
  -- Create autocmd to clean up terminal processes when Neovim exits
  vim.api.nvim_create_autocmd("VimLeave", {
    group = vim.api.nvim_create_augroup("OpenCodeTerminalCleanup", { clear = true }),
    callback = function()
      if jobid and jobid > 0 then
        logger.debug("terminal", "VimLeave: Cleaning up terminal process")
        -- Kill the job and any children
        pcall(function()
          vim.fn.jobstop(jobid)
        end)
        
        -- On Unix, kill process group
        if vim.fn.has("unix") == 1 then
          vim.fn.system("pkill -9 -P " .. tostring(jobid) .. " 2>/dev/null || true")
        end
      end
    end,
  })
end

--- @param cmd_string string
--- @param env_table table
--- @param effective_config table
--- @param focus boolean|nil
function M.open(cmd_string, env_table, effective_config, focus)
  focus = utils.normalize_focus(focus)

  if is_valid() then
    -- Check if terminal exists but is hidden (no window)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
      -- Terminal is hidden, show it by calling show_hidden_terminal
      show_hidden_terminal(effective_config, focus)
    else
      -- Terminal is already visible
      if focus then
        focus_terminal()
      end
    end
  else
    -- Check if there's an existing terminal we lost track of
    local existing_buf, existing_win = find_existing_managed_terminal()
    if existing_buf and existing_win then
      -- Recover the existing terminal
      bufnr = existing_buf
      winid = existing_win
      -- Note: We can't recover the job ID easily, but it's less critical
      logger.debug("terminal", "Recovered existing terminal")
      if focus then
        focus_terminal() -- Focus recovered terminal
      end
      -- If focus=false, preserve user context by staying in current window
    else
      if not open_terminal(cmd_string, env_table, effective_config, focus) then
        vim.notify("Failed to open Claude terminal using native fallback.", vim.log.levels.ERROR)
      end
    end
  end
end

function M.close()
  close_terminal()
end

---Simple toggle: always show/hide terminal regardless of focus
---@param cmd_string string
---@param env_table table
---@param effective_config OpenCodeTerminalConfig
function M.simple_toggle(cmd_string, env_table, effective_config)
  -- Check if we have a valid terminal buffer (process running)
  local has_buffer = bufnr and vim.api.nvim_buf_is_valid(bufnr)
  local is_visible = has_buffer and is_terminal_visible()

  if is_visible then
    -- Terminal is visible, hide it (but keep process running)
    hide_terminal()
  else
    -- Terminal is not visible
    if has_buffer then
      -- Terminal process exists but is hidden, show it
      if show_hidden_terminal(effective_config, true) then
        logger.debug("terminal", "Showing hidden terminal")
      else
        logger.error("terminal", "Failed to show hidden terminal")
      end
    else
      -- No terminal process exists, check if there's an existing one we lost track of
      local existing_buf, existing_win = find_existing_managed_terminal()
      if existing_buf and existing_win then
        -- Recover the existing terminal
        bufnr = existing_buf
        winid = existing_win
        logger.debug("terminal", "Recovered existing terminal")
        focus_terminal()
      else
        -- No existing terminal found, create a new one
        if not open_terminal(cmd_string, env_table, effective_config) then
          vim.notify("Failed to open Claude terminal using native fallback (simple_toggle).", vim.log.levels.ERROR)
        end
      end
    end
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused
---@param cmd_string string
---@param env_table table
---@param effective_config OpenCodeTerminalConfig
function M.focus_toggle(cmd_string, env_table, effective_config)
  -- Check if we have a valid terminal buffer (process running)
  local has_buffer = bufnr and vim.api.nvim_buf_is_valid(bufnr)
  local is_visible = has_buffer and is_terminal_visible()

  if has_buffer then
    -- Terminal process exists
    if is_visible then
      -- Terminal is visible - check if we're currently in it
      local current_win_id = vim.api.nvim_get_current_win()
      if winid == current_win_id then
        -- We're in the terminal window, hide it (but keep process running)
        hide_terminal()
      else
        -- Terminal is visible but we're not in it, focus it
        focus_terminal()
      end
    else
      -- Terminal process exists but is hidden, show it
      if show_hidden_terminal(effective_config, true) then
        logger.debug("terminal", "Showing hidden terminal")
      else
        logger.error("terminal", "Failed to show hidden terminal")
      end
    end
  else
    -- No terminal process exists, check if there's an existing one we lost track of
    local existing_buf, existing_win = find_existing_managed_terminal()
    if existing_buf and existing_win then
      -- Recover the existing terminal
      bufnr = existing_buf
      winid = existing_win
      logger.debug("terminal", "Recovered existing terminal")

      -- Check if we're currently in this recovered terminal
      local current_win_id = vim.api.nvim_get_current_win()
      if existing_win == current_win_id then
        -- We're in the recovered terminal, hide it
        hide_terminal()
      else
        -- Focus the recovered terminal
        focus_terminal()
      end
    else
      -- No existing terminal found, create a new one
      if not open_terminal(cmd_string, env_table, effective_config) then
        vim.notify("Failed to open Claude terminal using native fallback (focus_toggle).", vim.log.levels.ERROR)
      end
    end
  end
end

--- Legacy toggle function for backward compatibility (defaults to simple_toggle)
--- @param cmd_string string
--- @param env_table table
--- @param effective_config OpenCodeTerminalConfig
function M.toggle(cmd_string, env_table, effective_config)
  M.simple_toggle(cmd_string, env_table, effective_config)
end

---Send text to the running terminal job.
---@param text string
---@return boolean success
---@return string? error
function M.send_input(text)
  if type(text) ~= "string" or text == "" then
    return false, "send_input requires a non-empty string"
  end

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "No active terminal buffer"
  end

  local channel_id = jobid
  if not channel_id or channel_id <= 0 then
    local ok, terminal_job_id = pcall(function()
      return vim.b[bufnr].terminal_job_id
    end)
    if ok then
      channel_id = terminal_job_id
    end
  end

  if not channel_id or channel_id <= 0 then
    return false, "No active terminal job"
  end

  local ok, err = pcall(vim.api.nvim_chan_send, channel_id, text)
  if not ok then
    return false, tostring(err)
  end

  return true, nil
end

--- @return number|nil
function M.get_active_bufnr()
  if is_valid() then
    return bufnr
  end
  return nil
end

--- @return boolean
function M.is_available()
  return true -- Native provider is always available
end

--- @type OpenCodeTerminalProvider
return M
