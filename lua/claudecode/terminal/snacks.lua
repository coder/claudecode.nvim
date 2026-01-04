---Snacks.nvim terminal provider for Claude Code.
---Supports multiple terminal sessions.
---Buffer-only management - window_manager handles all window operations.
---@module 'claudecode.terminal.snacks'

local M = {}

local snacks_available, Snacks = pcall(require, "snacks")
local osc_handler = require("claudecode.terminal.osc_handler")
local session_manager = require("claudecode.session")
local utils = require("claudecode.utils")

-- Legacy single terminal support (backward compatibility)
local terminal = nil

-- Multi-session terminal storage
---@type table<string, table> Map of session_id -> terminal instance
local terminals = {}

-- Track sessions being intentionally closed (to suppress exit error messages)
---@type table<string, boolean>
local closing_sessions = {}

--- @return boolean
local function is_available()
  return snacks_available and Snacks and Snacks.terminal ~= nil
end

---Setup event handlers for terminal instance
---@param term_instance table The Snacks terminal instance
---@param config table Configuration options
---@param session_id string|nil Optional session ID for multi-session support
local function setup_terminal_events(term_instance, config, session_id)
  local logger = require("claudecode.logger")
  local window_manager = require("claudecode.terminal.window_manager")

  -- Handle command completion/exit - only if auto_close is enabled
  if config.auto_close then
    term_instance:on("TermClose", function()
      -- Check if this was an intentional close (via close_session_keep_window)
      local is_intentional_close = session_id and closing_sessions[session_id]

      -- Only show error if this wasn't an intentional close
      if vim.v.event.status ~= 0 and not is_intentional_close then
        logger.error("terminal", "Claude exited with code " .. vim.v.event.status .. ".\nCheck for any errors.")
      end

      -- If this was an intentional close, close_session_keep_window already handled
      -- the session switching - we just need minimal cleanup here
      if is_intentional_close then
        logger.debug("terminal", "TermClose for intentionally closed session, skipping switch logic")
        if session_id then
          terminals[session_id] = nil
          closing_sessions[session_id] = nil
        end
        if terminal == term_instance then
          terminal = nil
        end
        return
      end

      -- Check if there are other sessions before destroying
      local session_count = session_manager.get_session_count()
      local current_bufnr = term_instance.buf

      -- Track the exited session ID for cleanup
      local exited_session_id = session_id

      -- Clean up terminal state
      if session_id then
        terminals[session_id] = nil
        closing_sessions[session_id] = nil
        -- Destroy the session in session manager (only if it still exists)
        if session_manager.get_session(session_id) then
          session_manager.destroy_session(session_id)
        end
      else
        -- For legacy terminal, find and destroy associated session
        if term_instance.buf then
          local session = session_manager.find_session_by_bufnr(term_instance.buf)
          if session then
            exited_session_id = session.id
            logger.debug("terminal", "Destroying session for exited terminal: " .. session.id)
            if session_manager.get_session(session.id) then
              session_manager.destroy_session(session.id)
            end
          end
        end
      end

      vim.schedule(function()
        -- If there are other sessions, switch to the new active session
        if session_count > 1 then
          local new_active_id = session_manager.get_active_session_id()
          if new_active_id then
            local new_term = terminals[new_active_id]

            -- Fallback: check if any other terminal in our table is valid
            if not new_term or not new_term:buf_valid() then
              for sid, term in pairs(terminals) do
                if sid ~= exited_session_id and term and term:buf_valid() then
                  new_term = term
                  terminals[new_active_id] = new_term
                  logger.debug("terminal", "Recovered terminal from table for session: " .. new_active_id)
                  break
                end
              end
            end

            -- Fallback: check the global terminal variable
            if not new_term or not new_term:buf_valid() then
              if terminal and terminal:buf_valid() and terminal ~= term_instance then
                new_term = terminal
                terminals[new_active_id] = new_term
                logger.debug("terminal", "Recovered global terminal for session: " .. new_active_id)
              end
            end

            if new_term and new_term:buf_valid() and new_term.buf then
              -- Display the new session's buffer in window manager's window
              window_manager.display_buffer(new_term.buf, true)

              -- Update legacy terminal reference
              terminal = new_term

              -- Re-attach tabbar
              local winid = window_manager.get_window()
              if winid then
                local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
                if ok then
                  tabbar.attach(winid, new_term.buf, new_term)
                end
              end

              logger.debug("terminal", "Switched to session " .. new_active_id)

              -- Delete the old buffer after switching
              if current_bufnr and vim.api.nvim_buf_is_valid(current_bufnr) then
                vim.api.nvim_buf_delete(current_bufnr, { force = true })
              end

              vim.cmd.checktime()
              return
            end
          end
        end

        -- No other sessions or couldn't switch, close the window
        if terminal == term_instance then
          terminal = nil
        end
        window_manager.close_window()
        -- Delete the buffer
        if current_bufnr and vim.api.nvim_buf_is_valid(current_bufnr) then
          vim.api.nvim_buf_delete(current_bufnr, { force = true })
        end
        vim.cmd.checktime()
      end)
    end, { buf = true })
  end

  -- Handle buffer deletion
  term_instance:on("BufWipeout", function()
    logger.debug("terminal", "Terminal buffer wiped" .. (session_id and (" for session " .. session_id) or ""))

    -- Cleanup OSC handler
    if term_instance.buf then
      osc_handler.cleanup_buffer_handler(term_instance.buf)
    end

    if session_id then
      terminals[session_id] = nil
      if session_manager.get_session(session_id) then
        session_manager.destroy_session(session_id)
      end
    else
      if term_instance.buf then
        local session = session_manager.find_session_by_bufnr(term_instance.buf)
        if session then
          logger.debug("terminal", "Destroying session for wiped terminal: " .. session.id)
          if session_manager.get_session(session.id) then
            session_manager.destroy_session(session.id)
          end
        end
      end
      terminal = nil
    end
  end, { buf = true })
end

---Build initial title for session tabs
---@param session_id string|nil Optional session ID
---@return string title The title string
local function build_initial_title(session_id)
  local sm = require("claudecode.session")
  local sessions = sm.list_sessions()
  local active_id = session_id or sm.get_active_session_id()

  if #sessions == 0 then
    return "Claude Code"
  end

  local parts = {}
  for i, session in ipairs(sessions) do
    local is_active = session.id == active_id
    local name = session.name or ("Session " .. i)
    if #name > 15 then
      name = name:sub(1, 12) .. "..."
    end
    local label = string.format("%d:%s", i, name)
    if is_active then
      label = "[" .. label .. "]"
    end
    table.insert(parts, label)
  end
  table.insert(parts, "[+]")
  return table.concat(parts, " | ")
end

---Builds Snacks terminal options for buffer creation (no window focus)
---@param config ClaudeCodeTerminalConfig Terminal configuration
---@param env_table table Environment variables to set for the terminal process
---@param session_id string|nil Optional session ID for title
---@return snacks.terminal.Opts opts Snacks terminal options
local function build_opts(config, env_table, session_id)
  -- Build keys table with optional exit_terminal keymap
  local keys = {
    claude_new_line = {
      "<S-CR>",
      function()
        vim.api.nvim_feedkeys("\\", "t", true)
        vim.defer_fn(function()
          vim.api.nvim_feedkeys("\r", "t", true)
        end, 10)
      end,
      mode = "t",
      desc = "New line",
    },
  }

  -- Only add exit_terminal keymap to Snacks keys if smart ESC handling is disabled
  local esc_timeout = config.esc_timeout
  if (not esc_timeout or esc_timeout == 0) and config.keymaps and config.keymaps.exit_terminal then
    keys.claude_exit_terminal = {
      config.keymaps.exit_terminal,
      "<C-\\><C-n>",
      mode = "t",
      desc = "Exit terminal mode",
    }
  end

  -- Build title for tabs if enabled
  local title = nil
  if config.tabs and config.tabs.enabled then
    title = build_initial_title(session_id)
  end

  -- Merge user's snacks_win_opts
  local win_opts = vim.tbl_deep_extend("force", {
    position = config.split_side,
    width = config.split_width_percentage,
    height = 0,
    relative = "editor",
    keys = keys,
    title = title,
    title_pos = title and "center" or nil,
    wo = {},
  } --[[@as snacks.win.Config]], config.snacks_win_opts or {})

  return {
    env = env_table,
    cwd = config.cwd,
    start_insert = false, -- Don't auto-start insert, window_manager handles focus
    auto_insert = false,
    auto_close = false,
    win = win_opts,
  } --[[@as snacks.terminal.Opts]]
end

---Create a terminal buffer without keeping snacks' window
---Preserves existing window dimensions when window_manager already has a window
---@param cmd_string string Command to run
---@param env_table table Environment variables
---@param config table Terminal configuration
---@param session_id string Session ID
---@return table|nil term_instance The snacks terminal instance
local function create_terminal_buffer(cmd_string, env_table, config, session_id)
  local logger = require("claudecode.logger")
  local window_manager = require("claudecode.terminal.window_manager")

  -- Save existing window dimensions BEFORE snacks creates its window
  -- Snacks.terminal.open() will create a split that may affect our window size
  local saved_winid = window_manager.get_window()
  local saved_width, saved_height
  if saved_winid and vim.api.nvim_win_is_valid(saved_winid) then
    saved_width = vim.api.nvim_win_get_width(saved_winid)
    saved_height = vim.api.nvim_win_get_height(saved_winid)
    logger.debug("terminal", string.format("Saved window dimensions: %dx%d", saved_width, saved_height))
  end

  local opts = build_opts(config, env_table, session_id)
  local term_instance = Snacks.terminal.open(cmd_string, opts)

  if term_instance and term_instance:buf_valid() then
    -- Immediately close snacks' window (buffer stays alive)
    -- We'll display the buffer in window_manager's window instead
    if term_instance.win and vim.api.nvim_win_is_valid(term_instance.win) then
      pcall(vim.api.nvim_win_close, term_instance.win, false)
      term_instance.win = nil
      logger.debug("terminal", "Closed snacks window for session: " .. session_id)
    end

    -- Restore the original window dimensions if they were saved
    -- This fixes the issue where creating a new session resizes the window
    if saved_winid and vim.api.nvim_win_is_valid(saved_winid) and saved_width then
      vim.api.nvim_win_set_width(saved_winid, saved_width)
      if saved_height then
        vim.api.nvim_win_set_height(saved_winid, saved_height)
      end
      logger.debug("terminal", string.format("Restored window dimensions: %dx%d", saved_width, saved_height or 0))
    end

    setup_terminal_events(term_instance, config, session_id)
    return term_instance
  end

  return nil
end

function M.setup()
  -- No specific setup needed for Snacks provider
end

---Open a terminal using Snacks.nvim (legacy interface)
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
---@param focus boolean?
function M.open(cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local window_manager = require("claudecode.terminal.window_manager")
  focus = utils.normalize_focus(focus)

  if terminal and terminal:buf_valid() then
    -- Terminal exists, display it via window manager
    window_manager.display_buffer(terminal.buf, focus)
    return
  end

  -- Ensure a session exists
  local session_id = session_manager.ensure_session()

  -- Create terminal buffer
  local term_instance = create_terminal_buffer(cmd_string, env_table, config, session_id)

  if term_instance and term_instance:buf_valid() then
    terminal = term_instance
    terminals[session_id] = term_instance

    -- Display buffer via window manager
    window_manager.display_buffer(term_instance.buf, focus)

    -- Set up smart ESC handling if enabled
    local terminal_module = require("claudecode.terminal")
    if config.esc_timeout and config.esc_timeout > 0 and term_instance.buf then
      terminal_module.setup_terminal_keymaps(term_instance.buf, config)
    end

    -- Update session info
    session_manager.update_terminal_info(session_id, {
      bufnr = term_instance.buf,
      winid = window_manager.get_window(),
    })

    -- Attach tabbar
    local winid = window_manager.get_window()
    if winid then
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(winid) then
          local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
          if ok then
            tabbar.attach(winid, term_instance.buf, term_instance)
          end
        end
      end)
    end
  else
    terminal = nil
    local logger = require("claudecode.logger")
    logger.error("terminal", "Failed to open Claude terminal using Snacks")
    vim.notify("Failed to open Claude terminal using Snacks.", vim.log.levels.ERROR)
  end
end

---Close the terminal
function M.close()
  if not is_available() then
    return
  end
  local window_manager = require("claudecode.terminal.window_manager")
  window_manager.close_window()
end

---Simple toggle: always show/hide terminal regardless of focus
---@param cmd_string string
---@param env_table table
---@param config table
function M.simple_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local window_manager = require("claudecode.terminal.window_manager")
  local logger = require("claudecode.logger")

  if window_manager.is_visible() then
    -- Terminal is visible, hide it
    logger.debug("terminal", "Simple toggle: hiding terminal")
    window_manager.close_window()
  elseif terminal and terminal:buf_valid() then
    -- Terminal buffer exists but not visible, show it
    logger.debug("terminal", "Simple toggle: showing hidden terminal")
    window_manager.display_buffer(terminal.buf, true)
  else
    -- No terminal exists, create new one
    logger.debug("terminal", "Simple toggle: creating new terminal")
    M.open(cmd_string, env_table, config)
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused
---@param cmd_string string
---@param env_table table
---@param config table
function M.focus_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local window_manager = require("claudecode.terminal.window_manager")
  local logger = require("claudecode.logger")

  if not window_manager.is_visible() then
    -- Terminal not visible
    if terminal and terminal:buf_valid() then
      logger.debug("terminal", "Focus toggle: showing hidden terminal")
      window_manager.display_buffer(terminal.buf, true)
    else
      logger.debug("terminal", "Focus toggle: creating new terminal")
      M.open(cmd_string, env_table, config)
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

---Legacy toggle function for backward compatibility (defaults to simple_toggle)
---@param cmd_string string
---@param env_table table
---@param config table
function M.toggle(cmd_string, env_table, config)
  M.simple_toggle(cmd_string, env_table, config)
end

---Get the active terminal buffer number
---@return number?
function M.get_active_bufnr()
  if terminal and terminal:buf_valid() and terminal.buf then
    if vim.api.nvim_buf_is_valid(terminal.buf) then
      return terminal.buf
    end
  end
  return nil
end

---Is the terminal provider available?
---@return boolean
function M.is_available()
  return is_available()
end

---For testing purposes
---@return table? terminal The terminal instance, or nil
function M._get_terminal_for_test()
  return terminal
end

-- ============================================================================
-- Multi-session support functions
-- ============================================================================

---Open a terminal for a specific session
---@param session_id string The session ID
---@param cmd_string string The command to run
---@param env_table table Environment variables
---@param config ClaudeCodeTerminalConfig Terminal configuration
---@param focus boolean? Whether to focus the terminal
function M.open_session(session_id, cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")
  local window_manager = require("claudecode.terminal.window_manager")
  focus = utils.normalize_focus(focus)

  -- Check if this session already has a terminal
  local existing_term = terminals[session_id]
  if existing_term and existing_term:buf_valid() then
    -- Terminal exists, display it via window manager
    window_manager.display_buffer(existing_term.buf, focus)

    -- Update tabbar
    local winid = window_manager.get_window()
    if winid then
      local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
      if ok then
        tabbar.attach(winid, existing_term.buf, existing_term)
      end
    end

    logger.debug("terminal", "Displayed existing terminal for session: " .. session_id)
    return
  end

  -- Create new terminal buffer for this session
  local term_instance = create_terminal_buffer(cmd_string, env_table, config, session_id)

  if term_instance and term_instance:buf_valid() then
    terminals[session_id] = term_instance
    terminal = term_instance -- Also set as legacy terminal

    -- Display buffer via window manager
    window_manager.display_buffer(term_instance.buf, focus)

    -- Update session manager with terminal info
    local terminal_module = require("claudecode.terminal")
    terminal_module.update_session_terminal_info(session_id, {
      bufnr = term_instance.buf,
      winid = window_manager.get_window(),
    })

    -- Set up smart ESC handling if enabled
    if config.esc_timeout and config.esc_timeout > 0 and term_instance.buf then
      terminal_module.setup_terminal_keymaps(term_instance.buf, config)
    end

    -- Setup OSC title handler
    if term_instance.buf then
      osc_handler.setup_buffer_handler(term_instance.buf, function(title)
        if title and title ~= "" then
          session_manager.update_session_name(session_id, title)
        end
      end)
    end

    -- Attach tabbar
    local winid = window_manager.get_window()
    if winid then
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(winid) then
          local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
          if ok then
            tabbar.attach(winid, term_instance.buf, term_instance)
          end
        end
      end)
    end

    logger.debug("terminal", "Opened terminal for session: " .. session_id)
  else
    logger.error("terminal", "Failed to open terminal for session: " .. session_id)
  end
end

---Close a terminal for a specific session
---@param session_id string The session ID
function M.close_session(session_id)
  if not is_available() then
    return
  end

  local term_instance = terminals[session_id]
  if term_instance and term_instance:buf_valid() then
    -- Mark as intentional close to suppress error message
    closing_sessions[session_id] = true

    -- Cleanup OSC handler
    if term_instance.buf then
      osc_handler.cleanup_buffer_handler(term_instance.buf)
    end

    -- Delete the buffer
    if term_instance.buf and vim.api.nvim_buf_is_valid(term_instance.buf) then
      vim.api.nvim_buf_delete(term_instance.buf, { force = true })
    end

    terminals[session_id] = nil

    -- If this was the legacy terminal, clear it too
    if terminal == term_instance then
      terminal = nil
    end
  end
end

---Close a session's terminal but keep window open and switch to another session
---@param old_session_id string The session ID to close
---@param new_session_id string The session ID to switch to
---@param effective_config ClaudeCodeTerminalConfig Terminal configuration
function M.close_session_keep_window(old_session_id, new_session_id, effective_config)
  if not is_available() then
    return
  end

  local logger = require("claudecode.logger")
  local window_manager = require("claudecode.terminal.window_manager")

  local old_term = terminals[old_session_id]
  local new_term = terminals[new_session_id]

  -- Try to find the new session's terminal if not in terminals table
  if not new_term or not new_term:buf_valid() then
    local session_data = session_manager.get_session(new_session_id)
    if session_data and session_data.terminal_bufnr then
      if terminal and terminal:buf_valid() and terminal.buf == session_data.terminal_bufnr then
        new_term = terminal
        terminals[new_session_id] = new_term
        logger.debug("terminal", "Recovered legacy terminal for new session: " .. new_session_id)
      end
    end
  end

  -- Try to find old_term from legacy terminal
  if not old_term then
    local old_session_data = session_manager.get_session(old_session_id)
    if old_session_data and old_session_data.terminal_bufnr then
      if terminal and terminal:buf_valid() and terminal.buf == old_session_data.terminal_bufnr then
        old_term = terminal
        logger.debug("terminal", "Using legacy terminal as old_term for: " .. old_session_id)
      end
    end
    if not old_term then
      logger.debug("terminal", "No terminal found for old session: " .. old_session_id)
      return
    end
  end

  -- Mark as intentional close
  closing_sessions[old_session_id] = true

  -- If new terminal exists, display it via window manager
  if new_term and new_term:buf_valid() then
    window_manager.display_buffer(new_term.buf, true)

    -- Update legacy terminal reference
    terminal = new_term

    -- Update tabbar
    local winid = window_manager.get_window()
    if winid then
      local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
      if ok then
        tabbar.attach(winid, new_term.buf, new_term)
      end
    end
  else
    -- No valid new_term found - close the window
    logger.warn("terminal", "No valid terminal found for new session: " .. new_session_id)
    window_manager.close_window()
  end

  -- Clean up old terminal's buffer
  if old_term and old_term:buf_valid() then
    if old_term.buf then
      osc_handler.cleanup_buffer_handler(old_term.buf)
    end
    if old_term.buf and vim.api.nvim_buf_is_valid(old_term.buf) then
      vim.api.nvim_buf_delete(old_term.buf, { force = true })
    end
  end

  terminals[old_session_id] = nil
  closing_sessions[old_session_id] = nil

  logger.debug("terminal", "Closed session " .. old_session_id .. " and switched to " .. new_session_id)
end

---Focus a terminal for a specific session
---@param session_id string The session ID
---@param config ClaudeCodeTerminalConfig|nil Terminal configuration for showing hidden terminal
function M.focus_session(session_id, config)
  if not is_available() then
    return
  end

  local logger = require("claudecode.logger")
  local window_manager = require("claudecode.terminal.window_manager")

  local term_instance = terminals[session_id]

  -- If not found in terminals table, try fallback to legacy terminal
  if not term_instance or not term_instance:buf_valid() then
    local session_mod = require("claudecode.session")
    local session = session_mod.get_session(session_id)
    if
      session
      and session.terminal_bufnr
      and terminal
      and terminal:buf_valid()
      and terminal.buf == session.terminal_bufnr
    then
      logger.debug("terminal", "Registering legacy terminal for session: " .. session_id)
      M.register_terminal_for_session(session_id, terminal.buf)
      term_instance = terminals[session_id]
    end

    if not term_instance or not term_instance:buf_valid() then
      logger.debug("terminal", "Cannot focus invalid session: " .. session_id)
      return
    end
  end

  -- Display buffer via window manager
  window_manager.display_buffer(term_instance.buf, true)

  -- Update legacy terminal reference
  terminal = term_instance

  -- Update tabbar
  local winid = window_manager.get_window()
  if winid then
    local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
    if ok then
      tabbar.attach(winid, term_instance.buf, term_instance)
    end
  end

  logger.debug("terminal", "Focused session: " .. session_id)
end

---Get the buffer number for a session's terminal
---@param session_id string The session ID
---@return number|nil bufnr The buffer number or nil
function M.get_session_bufnr(session_id)
  local term_instance = terminals[session_id]
  if term_instance and term_instance:buf_valid() and term_instance.buf then
    return term_instance.buf
  end
  return nil
end

---Get all session IDs with active terminals
---@return string[] session_ids Array of session IDs
function M.get_active_session_ids()
  local ids = {}
  for session_id, term_instance in pairs(terminals) do
    if term_instance and term_instance:buf_valid() then
      table.insert(ids, session_id)
    end
  end
  return ids
end

---Register an existing terminal (from legacy path) with a session ID
---@param session_id string The session ID
---@param term_bufnr number|nil The buffer number (uses legacy terminal's bufnr if nil)
function M.register_terminal_for_session(session_id, term_bufnr)
  local logger = require("claudecode.logger")

  if not term_bufnr and terminal and terminal:buf_valid() then
    term_bufnr = terminal.buf
  end

  if not term_bufnr then
    logger.debug("terminal", "Cannot register nil terminal for session: " .. session_id)
    return
  end

  -- Check if already registered to another session
  for sid, term_instance in pairs(terminals) do
    if term_instance and term_instance:buf_valid() and term_instance.buf == term_bufnr and sid ~= session_id then
      logger.debug(
        "terminal",
        "Terminal already registered to session " .. sid .. ", not registering to " .. session_id
      )
      return
    end
  end

  -- Check if this session already has a different terminal
  local existing_term = terminals[session_id]
  if existing_term and existing_term:buf_valid() and existing_term.buf ~= term_bufnr then
    logger.debug("terminal", "Session " .. session_id .. " already has a different terminal")
    return
  end

  -- Register the legacy terminal with the session
  if terminal and terminal:buf_valid() and terminal.buf == term_bufnr then
    terminals[session_id] = terminal
    logger.debug("terminal", "Registered terminal (bufnr=" .. term_bufnr .. ") for session: " .. session_id)
  else
    logger.debug("terminal", "Cannot register: terminal bufnr mismatch for session: " .. session_id)
  end
end

---@type ClaudeCodeTerminalProvider
return M
