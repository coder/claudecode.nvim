---Native Neovim terminal provider for Claude Code.
---Supports multiple terminal sessions.
---Buffer-only management - window_manager handles all window operations.
---@module 'claudecode.terminal.native'

local M = {}

local logger = require("claudecode.logger")
local osc_handler = require("claudecode.terminal.osc_handler")
local session_manager = require("claudecode.session")
local utils = require("claudecode.utils")

-- Legacy single terminal support (backward compatibility)
local bufnr = nil
local jobid = nil
local tip_shown = false

-- Multi-session terminal storage
---@class NativeTerminalState
---@field bufnr number|nil
---@field jobid number|nil

---@type table<string, NativeTerminalState> Map of session_id -> terminal state
local terminals = {}

---@type ClaudeCodeTerminalConfig
local config = require("claudecode.terminal").defaults

local function cleanup_state()
  bufnr = nil
  jobid = nil
end

local function is_valid()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    cleanup_state()
    return false
  end
  return true
end

---Create a new terminal buffer (without window)
---@param cmd_string string Command to run
---@param env_table table Environment variables
---@param effective_config ClaudeCodeTerminalConfig Terminal configuration
---@param session_id string|nil Session ID for exit handler
---@return number|nil bufnr The buffer number or nil on failure
---@return number|nil jobid The job ID or nil on failure
local function create_terminal_buffer(cmd_string, env_table, effective_config, session_id)
  local window_manager = require("claudecode.terminal.window_manager")

  -- Create a new buffer
  local new_bufnr = vim.api.nvim_create_buf(false, true)
  if not new_bufnr or new_bufnr == 0 then
    return nil, nil
  end

  vim.bo[new_bufnr].bufhidden = "hide"

  local term_cmd_arg
  if cmd_string:find(" ", 1, true) then
    term_cmd_arg = vim.split(cmd_string, " ", { plain = true, trimempty = false })
  else
    term_cmd_arg = { cmd_string }
  end

  -- Open terminal in the buffer
  local new_jobid
  vim.api.nvim_buf_call(new_bufnr, function()
    new_jobid = vim.fn.termopen(term_cmd_arg, {
      env = env_table,
      cwd = effective_config.cwd,
      on_exit = function(job_id, _, _)
        vim.schedule(function()
          -- For multi-session
          if session_id then
            local state = terminals[session_id]
            if state and job_id == state.jobid then
              logger.debug("terminal", "Terminal process exited for session: " .. session_id)

              local current_bufnr = state.bufnr

              -- Cleanup OSC handler
              if current_bufnr then
                osc_handler.cleanup_buffer_handler(current_bufnr)
              end

              local session_count = session_manager.get_session_count()
              terminals[session_id] = nil

              if session_manager.get_session(session_id) then
                session_manager.destroy_session(session_id)
              end

              if not effective_config.auto_close then
                return
              end

              -- If there are other sessions, switch to the new active session
              if session_count > 1 then
                local new_active_id = session_manager.get_active_session_id()
                if new_active_id then
                  local new_state = terminals[new_active_id]
                  if new_state and new_state.bufnr and vim.api.nvim_buf_is_valid(new_state.bufnr) then
                    window_manager.display_buffer(new_state.bufnr, true)

                    -- Update legacy state
                    bufnr = new_state.bufnr
                    jobid = new_state.jobid

                    -- Re-attach tabbar
                    local winid = window_manager.get_window()
                    if winid then
                      local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
                      if ok then
                        tabbar.attach(winid, new_state.bufnr)
                      end
                    end

                    -- Delete old buffer
                    if current_bufnr and vim.api.nvim_buf_is_valid(current_bufnr) then
                      vim.api.nvim_buf_delete(current_bufnr, { force = true })
                    end
                    return
                  end
                end
              end

              -- No other sessions, close the window
              window_manager.close_window()
              if current_bufnr and vim.api.nvim_buf_is_valid(current_bufnr) then
                vim.api.nvim_buf_delete(current_bufnr, { force = true })
              end
            end
          else
            -- Legacy terminal exit handling
            if job_id == jobid then
              logger.debug("terminal", "Terminal process exited, cleaning up")

              local current_bufnr = bufnr

              if current_bufnr then
                osc_handler.cleanup_buffer_handler(current_bufnr)
              end

              local session_count = session_manager.get_session_count()
              local session = session_manager.find_session_by_bufnr(current_bufnr)
              if session then
                logger.debug("terminal", "Destroying session for exited terminal: " .. session.id)
                if session_manager.get_session(session.id) then
                  session_manager.destroy_session(session.id)
                end
              end

              cleanup_state()

              if not effective_config.auto_close then
                return
              end

              -- If there are other sessions, switch to one
              if session_count > 1 then
                local new_active_id = session_manager.get_active_session_id()
                if new_active_id then
                  local new_state = terminals[new_active_id]
                  if new_state and new_state.bufnr and vim.api.nvim_buf_is_valid(new_state.bufnr) then
                    window_manager.display_buffer(new_state.bufnr, true)

                    bufnr = new_state.bufnr
                    jobid = new_state.jobid

                    local winid = window_manager.get_window()
                    if winid then
                      local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
                      if ok then
                        tabbar.attach(winid, new_state.bufnr)
                      end
                    end

                    if current_bufnr and vim.api.nvim_buf_is_valid(current_bufnr) then
                      vim.api.nvim_buf_delete(current_bufnr, { force = true })
                    end
                    return
                  end
                end
              end

              window_manager.close_window()
            end
          end
        end)
      end,
    })
  end)

  if not new_jobid or new_jobid == 0 then
    vim.api.nvim_buf_delete(new_bufnr, { force = true })
    return nil, nil
  end

  return new_bufnr, new_jobid
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
  local window_manager = require("claudecode.terminal.window_manager")
  focus = utils.normalize_focus(focus)

  if is_valid() then
    -- Terminal buffer exists, display it via window manager
    window_manager.display_buffer(bufnr, focus)
    return
  end

  -- Ensure a session exists
  local session_id = session_manager.ensure_session()

  -- Create terminal buffer
  local new_bufnr, new_jobid = create_terminal_buffer(cmd_string, env_table, effective_config, nil)
  if not new_bufnr then
    vim.notify("Failed to open Claude terminal using native fallback.", vim.log.levels.ERROR)
    return
  end

  bufnr = new_bufnr
  jobid = new_jobid

  -- Display buffer via window manager
  window_manager.display_buffer(bufnr, focus)

  -- Set up terminal keymaps
  local terminal_module = require("claudecode.terminal")
  terminal_module.setup_terminal_keymaps(bufnr, config)

  -- Update session info
  session_manager.update_terminal_info(session_id, {
    bufnr = bufnr,
    winid = window_manager.get_window(),
    jobid = jobid,
  })

  -- Also register in terminals table
  terminals[session_id] = {
    bufnr = bufnr,
    jobid = jobid,
  }

  -- Attach tabbar
  local winid = window_manager.get_window()
  if winid then
    local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
    if ok then
      tabbar.attach(winid, bufnr)
    end
  end

  if config.show_native_term_exit_tip and not tip_shown then
    local exit_key = config.keymaps and config.keymaps.exit_terminal or "Ctrl-\\ Ctrl-N"
    vim.notify("Native terminal opened. Press " .. exit_key .. " to return to Normal mode.", vim.log.levels.INFO)
    tip_shown = true
  end
end

function M.close()
  local window_manager = require("claudecode.terminal.window_manager")
  window_manager.close_window()
end

---Simple toggle: always show/hide terminal regardless of focus
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.simple_toggle(cmd_string, env_table, effective_config)
  local window_manager = require("claudecode.terminal.window_manager")

  if window_manager.is_visible() then
    -- Terminal is visible, hide it
    logger.debug("terminal", "Simple toggle: hiding terminal")
    window_manager.close_window()
  elseif is_valid() then
    -- Terminal buffer exists but not visible, show it
    logger.debug("terminal", "Simple toggle: showing hidden terminal")
    window_manager.display_buffer(bufnr, true)
  else
    -- No terminal exists, create new one
    logger.debug("terminal", "Simple toggle: creating new terminal")
    M.open(cmd_string, env_table, effective_config)
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.focus_toggle(cmd_string, env_table, effective_config)
  local window_manager = require("claudecode.terminal.window_manager")

  if not window_manager.is_visible() then
    -- Terminal not visible
    if is_valid() then
      logger.debug("terminal", "Focus toggle: showing hidden terminal")
      window_manager.display_buffer(bufnr, true)
    else
      logger.debug("terminal", "Focus toggle: creating new terminal")
      M.open(cmd_string, env_table, effective_config)
    end
  else
    -- Terminal is visible
    local winid = window_manager.get_window()
    local current_win = vim.api.nvim_get_current_win()

    if winid == current_win then
      -- We're focused on terminal, hide it
      logger.debug("terminal", "Focus toggle: hiding terminal (currently focused)")
      window_manager.close_window()
    else
      -- Terminal visible but not focused, focus it
      logger.debug("terminal", "Focus toggle: focusing terminal")
      vim.api.nvim_set_current_win(winid)
      vim.cmd("startinsert")
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

---Open a terminal for a specific session
---@param session_id string The session ID
---@param cmd_string string The command to run
---@param env_table table Environment variables
---@param effective_config ClaudeCodeTerminalConfig Terminal configuration
---@param focus boolean? Whether to focus the terminal
function M.open_session(session_id, cmd_string, env_table, effective_config, focus)
  local window_manager = require("claudecode.terminal.window_manager")
  focus = utils.normalize_focus(focus)

  logger.debug("terminal", "open_session called for: " .. session_id)

  -- Check if this session already has a valid terminal buffer
  if is_session_valid(session_id) then
    -- Display existing buffer via window manager
    window_manager.display_buffer(terminals[session_id].bufnr, focus)

    -- Update legacy state
    bufnr = terminals[session_id].bufnr
    jobid = terminals[session_id].jobid

    -- Re-attach tabbar
    local winid = window_manager.get_window()
    if winid then
      local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
      if ok then
        tabbar.attach(winid, terminals[session_id].bufnr)
      end
    end

    logger.debug("terminal", "Displayed existing terminal for session: " .. session_id)
    return
  end

  -- Create new terminal buffer for this session
  local new_bufnr, new_jobid = create_terminal_buffer(cmd_string, env_table, effective_config, session_id)
  if not new_bufnr then
    vim.notify("Failed to open native terminal for session: " .. session_id, vim.log.levels.ERROR)
    return
  end

  -- Display buffer via window manager
  window_manager.display_buffer(new_bufnr, focus)

  -- Set up terminal keymaps
  local terminal_module = require("claudecode.terminal")
  terminal_module.setup_terminal_keymaps(new_bufnr, config)

  -- Store session state
  terminals[session_id] = {
    bufnr = new_bufnr,
    jobid = new_jobid,
  }

  -- Update legacy state
  bufnr = new_bufnr
  jobid = new_jobid

  -- Update session manager
  terminal_module.update_session_terminal_info(session_id, {
    bufnr = new_bufnr,
    winid = window_manager.get_window(),
    jobid = new_jobid,
  })

  -- Setup OSC title handler
  osc_handler.setup_buffer_handler(new_bufnr, function(title)
    if title and title ~= "" then
      session_manager.update_session_name(session_id, title)
    end
  end)

  -- Attach tabbar
  local winid = window_manager.get_window()
  if winid then
    local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
    if ok then
      tabbar.attach(winid, new_bufnr)
    end
  end

  if config.show_native_term_exit_tip and not tip_shown then
    local exit_key = config.keymaps and config.keymaps.exit_terminal or "Ctrl-\\ Ctrl-N"
    vim.notify("Native terminal opened. Press " .. exit_key .. " to return to Normal mode.", vim.log.levels.INFO)
    tip_shown = true
  end

  logger.debug("terminal", "Opened terminal for session: " .. session_id)
end

---Close a terminal for a specific session
---@param session_id string The session ID
function M.close_session(session_id)
  local state = terminals[session_id]
  if not state then
    return
  end

  -- Clean up the buffer if it exists
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    osc_handler.cleanup_buffer_handler(state.bufnr)
    vim.api.nvim_buf_delete(state.bufnr, { force = true })
  end

  terminals[session_id] = nil

  -- If this was the legacy terminal, clear it too
  if bufnr == state.bufnr then
    cleanup_state()
  end
end

---Close a session's terminal but keep window open and switch to another session
---@param old_session_id string The session ID to close
---@param new_session_id string The session ID to switch to
---@param effective_config ClaudeCodeTerminalConfig Terminal configuration
function M.close_session_keep_window(old_session_id, new_session_id, effective_config)
  local window_manager = require("claudecode.terminal.window_manager")

  local old_state = terminals[old_session_id]
  local new_state = terminals[new_session_id]

  -- Try to recover new_state from session_manager if not in terminals table
  if not new_state or not new_state.bufnr or not vim.api.nvim_buf_is_valid(new_state.bufnr) then
    local session_data = session_manager.get_session(new_session_id)
    if session_data and session_data.terminal_bufnr and vim.api.nvim_buf_is_valid(session_data.terminal_bufnr) then
      if bufnr and bufnr == session_data.terminal_bufnr then
        new_state = {
          bufnr = bufnr,
          jobid = jobid,
        }
        terminals[new_session_id] = new_state
        logger.debug("terminal", "Recovered legacy terminal for new session: " .. new_session_id)
      end
    end
  end

  -- Try to recover old_state from legacy terminal
  if not old_state then
    local old_session_data = session_manager.get_session(old_session_id)
    if
      old_session_data
      and old_session_data.terminal_bufnr
      and vim.api.nvim_buf_is_valid(old_session_data.terminal_bufnr)
    then
      if bufnr and bufnr == old_session_data.terminal_bufnr then
        old_state = {
          bufnr = bufnr,
          jobid = jobid,
        }
        logger.debug("terminal", "Using legacy terminal as old_state for: " .. old_session_id)
      end
    end
    if not old_state then
      logger.debug("terminal", "No terminal found for old session: " .. old_session_id)
      return
    end
  end

  -- If new terminal exists, display it via window manager
  if new_state and new_state.bufnr and vim.api.nvim_buf_is_valid(new_state.bufnr) then
    window_manager.display_buffer(new_state.bufnr, true)

    -- Update legacy state
    bufnr = new_state.bufnr
    jobid = new_state.jobid

    -- Update tabbar
    local winid = window_manager.get_window()
    if winid then
      local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
      if ok then
        tabbar.attach(winid, new_state.bufnr)
      end
    end
  else
    -- No valid new_state found - close the window
    logger.warn("terminal", "No valid terminal found for new session: " .. new_session_id)
    window_manager.close_window()
  end

  -- Clean up old terminal's buffer
  if old_state and old_state.bufnr and vim.api.nvim_buf_is_valid(old_state.bufnr) then
    osc_handler.cleanup_buffer_handler(old_state.bufnr)
    vim.api.nvim_buf_delete(old_state.bufnr, { force = true })
  end

  terminals[old_session_id] = nil

  logger.debug("terminal", "Closed session " .. old_session_id .. " and switched to " .. new_session_id)
end

---Focus a terminal for a specific session
---@param session_id string The session ID
---@param effective_config ClaudeCodeTerminalConfig|nil Terminal configuration
function M.focus_session(session_id, effective_config)
  local window_manager = require("claudecode.terminal.window_manager")

  -- Check if session is valid in terminals table
  if not is_session_valid(session_id) then
    -- Fallback: Check if legacy terminal matches the session's bufnr
    local session_mod = require("claudecode.session")
    local session = session_mod.get_session(session_id)
    if session and session.terminal_bufnr and bufnr and bufnr == session.terminal_bufnr then
      logger.debug("terminal", "Registering legacy terminal for session: " .. session_id)
      M.register_terminal_for_session(session_id, bufnr)
    else
      logger.debug("terminal", "Cannot focus invalid session: " .. session_id)
      return
    end
  end

  local state = terminals[session_id]
  if not state or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    logger.debug("terminal", "Session has no valid buffer: " .. session_id)
    return
  end

  -- Display buffer via window manager
  window_manager.display_buffer(state.bufnr, true)

  -- Update legacy state
  bufnr = state.bufnr
  jobid = state.jobid

  -- Re-attach tabbar
  local winid = window_manager.get_window()
  if winid then
    local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
    if ok then
      tabbar.attach(winid, state.bufnr)
    end
  end

  logger.debug("terminal", "Focused session: " .. session_id)
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
    jobid = jobid,
  }

  logger.debug("terminal", "Registered terminal (bufnr=" .. term_bufnr .. ") for session: " .. session_id)
end

--- @type ClaudeCodeTerminalProvider
return M
