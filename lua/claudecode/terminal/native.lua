---Native Neovim terminal provider for Claude Code.
---Supports multiple terminal sessions.
---@module 'claudecode.terminal.native'

local M = {}

local logger = require("claudecode.logger")
local osc_handler = require("claudecode.terminal.osc_handler")
local session_manager = require("claudecode.session")
local utils = require("claudecode.utils")

-- Legacy single terminal support (backward compatibility)
local bufnr = nil
local winid = nil
local jobid = nil
local tip_shown = false

-- Multi-session terminal storage
---@class NativeTerminalState
---@field bufnr number|nil
---@field winid number|nil
---@field jobid number|nil

---@type table<string, NativeTerminalState> Map of session_id -> terminal state
local terminals = {}

-- Forward declaration for show_hidden_session_terminal
local show_hidden_session_terminal

---@type ClaudeCodeTerminalConfig
local config = require("claudecode.terminal").defaults

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

  -- Set up terminal keymaps (smart ESC handling)
  local terminal_module = require("claudecode.terminal")
  terminal_module.setup_terminal_keymaps(bufnr, config)

  if focus then
    -- Focus the terminal: switch to terminal window and enter insert mode
    vim.api.nvim_set_current_win(winid)
    vim.cmd("startinsert")
  else
    -- Preserve user context: return to the window they were in before terminal creation
    vim.api.nvim_set_current_win(original_win)
  end

  if config.show_native_term_exit_tip and not tip_shown then
    local exit_key = config.keymaps and config.keymaps.exit_terminal or "Ctrl-\\ Ctrl-N"
    vim.notify("Native terminal opened. Press " .. exit_key .. " to return to Normal mode.", vim.log.levels.INFO)
    tip_shown = true
  end
  return true
end

local function close_terminal()
  if is_valid() then
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

local function find_existing_claude_terminal()
  local buffers = vim.api.nvim_list_bufs()
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
      -- Check if this is a Claude Code terminal by examining the buffer name or terminal job
      local buf_name = vim.api.nvim_buf_get_name(buf)
      -- Terminal buffers often have names like "term://..." that include the command
      if buf_name:match("claude") then
        -- Additional check: see if there's a window displaying this buffer
        local windows = vim.api.nvim_list_wins()
        for _, win in ipairs(windows) do
          if vim.api.nvim_win_get_buf(win) == buf then
            logger.debug("terminal", "Found existing Claude terminal in buffer", buf, "window", win)
            return buf, win
          end
        end
      end
    end
  end
  return nil, nil
end

---Setup the terminal module
---@param term_config ClaudeCodeTerminalConfig
function M.setup(term_config)
  config = term_config
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
    -- Check if there's an existing Claude terminal we lost track of
    local existing_buf, existing_win = find_existing_claude_terminal()
    if existing_buf and existing_win then
      -- Recover the existing terminal
      bufnr = existing_buf
      winid = existing_win
      -- Note: We can't recover the job ID easily, but it's less critical
      logger.debug("terminal", "Recovered existing Claude terminal")
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
---@param effective_config ClaudeCodeTerminalConfig
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
      local existing_buf, existing_win = find_existing_claude_terminal()
      if existing_buf and existing_win then
        -- Recover the existing terminal
        bufnr = existing_buf
        winid = existing_win
        logger.debug("terminal", "Recovered existing Claude terminal")
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
---@param effective_config ClaudeCodeTerminalConfig
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
    local existing_buf, existing_win = find_existing_claude_terminal()
    if existing_buf and existing_win then
      -- Recover the existing terminal
      bufnr = existing_buf
      winid = existing_win
      logger.debug("terminal", "Recovered existing Claude terminal")

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
--- @param effective_config ClaudeCodeTerminalConfig
function M.toggle(cmd_string, env_table, effective_config)
  M.simple_toggle(cmd_string, env_table, effective_config)
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

-- ============================================================================
-- Multi-session support functions
-- ============================================================================

---Helper to check if a session's terminal is valid
---@param session_id string
---@return boolean
local function is_session_valid(session_id)
  local state = terminals[session_id]
  if not state or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return false
  end
  return true
end

---Helper to find window displaying a session's terminal
---@param session_id string
---@return number|nil winid
local function find_session_window(session_id)
  local state = terminals[session_id]
  if not state or not state.bufnr then
    return nil
  end

  local windows = vim.api.nvim_list_wins()
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_get_buf(win) == state.bufnr then
      state.winid = win
      return win
    end
  end
  return nil
end

---Hide all visible session terminals
---@param except_session_id string|nil Optional session ID to exclude from hiding
local function hide_all_session_terminals(except_session_id)
  for sid, state in pairs(terminals) do
    if sid ~= except_session_id and state and state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
      -- Find and close the window if it's visible
      local win = find_session_window(sid)
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, false)
        state.winid = nil
      end
    end
  end

  -- Also hide the legacy terminal if it's not one of the session terminals
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local is_session_terminal = false
    for _, state in pairs(terminals) do
      if state.bufnr == bufnr then
        is_session_terminal = true
        break
      end
    end

    if not is_session_terminal and winid and vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, false)
      winid = nil
    end
  end
end

---Open a terminal for a specific session
---@param session_id string The session ID
---@param cmd_string string The command to run
---@param env_table table Environment variables
---@param effective_config ClaudeCodeTerminalConfig Terminal configuration
---@param focus boolean? Whether to focus the terminal
function M.open_session(session_id, cmd_string, env_table, effective_config, focus)
  focus = utils.normalize_focus(focus)

  -- Check if this session already has a valid terminal
  if is_session_valid(session_id) then
    -- Hide other session terminals first
    hide_all_session_terminals(session_id)

    local win = find_session_window(session_id)

    if not win then
      -- Terminal is hidden, show it
      show_hidden_session_terminal(session_id, effective_config, focus)
    elseif focus then
      vim.api.nvim_set_current_win(win)
      vim.cmd("startinsert")
    end
    return
  end

  -- Hide all other session terminals before creating new one
  hide_all_session_terminals(nil)

  -- Create new terminal for this session
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

  local new_jobid = vim.fn.termopen(term_cmd_arg, {
    env = env_table,
    cwd = effective_config.cwd,
    on_exit = function(job_id, _, _)
      vim.schedule(function()
        local state = terminals[session_id]
        if state and job_id == state.jobid then
          logger.debug("terminal", "Terminal process exited for session: " .. session_id)

          local current_winid = state.winid
          local current_bufnr = state.bufnr

          -- Cleanup OSC handler before clearing state
          if current_bufnr then
            osc_handler.cleanup_buffer_handler(current_bufnr)
          end

          -- Clear session state
          terminals[session_id] = nil

          if not effective_config.auto_close then
            return
          end

          if current_winid and vim.api.nvim_win_is_valid(current_winid) then
            if current_bufnr and vim.api.nvim_buf_is_valid(current_bufnr) then
              if vim.api.nvim_win_get_buf(current_winid) == current_bufnr then
                vim.api.nvim_win_close(current_winid, true)
              end
            else
              vim.api.nvim_win_close(current_winid, true)
            end
          end
        end
      end)
    end,
  })

  if not new_jobid or new_jobid == 0 then
    vim.notify("Failed to open native terminal for session: " .. session_id, vim.log.levels.ERROR)
    vim.api.nvim_win_close(new_winid, true)
    vim.api.nvim_set_current_win(original_win)
    return
  end

  local new_bufnr = vim.api.nvim_get_current_buf()
  vim.bo[new_bufnr].bufhidden = "hide"

  -- Set up terminal keymaps (smart ESC handling)
  local terminal_module = require("claudecode.terminal")
  terminal_module.setup_terminal_keymaps(new_bufnr, config)

  -- Store session state
  terminals[session_id] = {
    bufnr = new_bufnr,
    winid = new_winid,
    jobid = new_jobid,
  }

  -- Also update legacy state for backward compatibility
  bufnr = new_bufnr
  winid = new_winid
  jobid = new_jobid

  -- Update session manager with terminal info
  terminal_module.update_session_terminal_info(session_id, {
    bufnr = new_bufnr,
    winid = new_winid,
    jobid = new_jobid,
  })

  -- Setup OSC title handler to capture terminal title changes
  osc_handler.setup_buffer_handler(new_bufnr, function(title)
    if title and title ~= "" then
      session_manager.update_session_name(session_id, title)
    end
  end)

  if focus then
    vim.api.nvim_set_current_win(new_winid)
    vim.cmd("startinsert")
  else
    vim.api.nvim_set_current_win(original_win)
  end

  if config.show_native_term_exit_tip and not tip_shown then
    local exit_key = config.keymaps and config.keymaps.exit_terminal or "Ctrl-\\ Ctrl-N"
    vim.notify("Native terminal opened. Press " .. exit_key .. " to return to Normal mode.", vim.log.levels.INFO)
    tip_shown = true
  end

  logger.debug("terminal", "Opened terminal for session: " .. session_id)
end

---Show a hidden session terminal
---@param session_id string
---@param effective_config table
---@param focus boolean?
local function show_hidden_session_terminal_impl(session_id, effective_config, focus)
  local state = terminals[session_id]
  if not state or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return false
  end

  -- Check if already visible
  local existing_win = find_session_window(session_id)
  if existing_win then
    if focus then
      vim.api.nvim_set_current_win(existing_win)
      vim.cmd("startinsert")
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
  vim.api.nvim_win_set_buf(new_winid, state.bufnr)
  state.winid = new_winid

  -- Notify terminal of window dimensions to fix cursor position after session switch
  -- Use actual window dimensions, not calculated ones (vim.o.lines includes statusline, cmdline, etc.)
  local chan = vim.bo[state.bufnr].channel
  if chan and chan > 0 then
    local actual_width = vim.api.nvim_win_get_width(new_winid)
    local actual_height = vim.api.nvim_win_get_height(new_winid)
    pcall(vim.fn.jobresize, chan, actual_width, actual_height)
  end

  if focus then
    vim.api.nvim_set_current_win(new_winid)
    vim.cmd("startinsert")
  else
    vim.api.nvim_set_current_win(original_win)
  end

  logger.debug("terminal", "Showed hidden terminal for session: " .. session_id)
  return true
end

-- Assign the implementation to forward declaration
show_hidden_session_terminal = show_hidden_session_terminal_impl

---Close a terminal for a specific session
---@param session_id string The session ID
function M.close_session(session_id)
  local state = terminals[session_id]
  if not state then
    return
  end

  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    vim.api.nvim_win_close(state.winid, true)
  end

  terminals[session_id] = nil

  -- If this was the legacy terminal, clear it too
  if bufnr == state.bufnr then
    cleanup_state()
  end
end

---Focus a terminal for a specific session
---@param session_id string The session ID
---@param effective_config ClaudeCodeTerminalConfig|nil Terminal configuration
function M.focus_session(session_id, effective_config)
  -- Check if session is valid in terminals table
  if not is_session_valid(session_id) then
    -- Fallback: Check if legacy terminal matches the session's bufnr from session_manager
    local session_mod = require("claudecode.session")
    local session = session_mod.get_session(session_id)
    if session and session.terminal_bufnr and bufnr and bufnr == session.terminal_bufnr then
      -- Legacy terminal matches this session, register it now
      logger.debug("terminal", "Registering legacy terminal for session: " .. session_id)
      M.register_terminal_for_session(session_id, bufnr)
    else
      logger.debug("terminal", "Cannot focus invalid session: " .. session_id)
      return
    end
  end

  -- Hide other session terminals first
  hide_all_session_terminals(session_id)

  local win = find_session_window(session_id)
  if not win then
    -- Terminal is hidden, show it
    if effective_config then
      show_hidden_session_terminal(session_id, effective_config, true)
    end
    return
  end

  -- Notify terminal of window dimensions to fix cursor position after session switch
  local state = terminals[session_id]
  if state and state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    local chan = vim.bo[state.bufnr].channel
    if chan and chan > 0 then
      local width = vim.api.nvim_win_get_width(win)
      local height = vim.api.nvim_win_get_height(win)
      pcall(vim.fn.jobresize, chan, width, height)
    end
  end

  vim.api.nvim_set_current_win(win)
  vim.cmd("startinsert")
end

---Get the buffer number for a session's terminal
---@param session_id string The session ID
---@return number|nil bufnr The buffer number or nil
function M.get_session_bufnr(session_id)
  local state = terminals[session_id]
  if state and state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    return state.bufnr
  end
  return nil
end

---Get all session IDs with active terminals
---@return string[] session_ids Array of session IDs
function M.get_active_session_ids()
  local ids = {}
  for session_id, state in pairs(terminals) do
    if state and state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
      table.insert(ids, session_id)
    end
  end
  return ids
end

---Register an existing terminal (from legacy path) with a session ID
---This is called when a terminal was created via simple_toggle/focus_toggle
---and we need to associate it with a session for multi-session support.
---@param session_id string The session ID
---@param term_bufnr number|nil The buffer number (uses legacy bufnr if nil)
function M.register_terminal_for_session(session_id, term_bufnr)
  term_bufnr = term_bufnr or bufnr

  if not term_bufnr or not vim.api.nvim_buf_is_valid(term_bufnr) then
    logger.debug("terminal", "Cannot register invalid terminal for session: " .. session_id)
    return
  end

  -- Check if this terminal is already registered to another session
  for sid, state in pairs(terminals) do
    if state and state.bufnr == term_bufnr and sid ~= session_id then
      -- Already registered to a different session, skip
      logger.debug(
        "terminal",
        "Terminal already registered to session " .. sid .. ", not registering to " .. session_id
      )
      return
    end
  end

  -- Check if this session already has a different terminal
  local existing_state = terminals[session_id]
  if existing_state and existing_state.bufnr and existing_state.bufnr ~= term_bufnr then
    logger.debug("terminal", "Session " .. session_id .. " already has a different terminal")
    return
  end

  -- Register the legacy terminal with the session
  terminals[session_id] = {
    bufnr = term_bufnr,
    winid = winid,
    jobid = jobid,
  }

  logger.debug("terminal", "Registered terminal (bufnr=" .. term_bufnr .. ") for session: " .. session_id)
end

--- @type ClaudeCodeTerminalProvider
return M
