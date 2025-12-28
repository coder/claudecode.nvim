---Snacks.nvim terminal provider for Claude Code.
---Supports multiple terminal sessions.
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

  -- Handle command completion/exit - only if auto_close is enabled
  if config.auto_close then
    term_instance:on("TermClose", function()
      -- Only show error if this wasn't an intentional close
      local is_intentional_close = session_id and closing_sessions[session_id]
      if vim.v.event.status ~= 0 and not is_intentional_close then
        logger.error("terminal", "Claude exited with code " .. vim.v.event.status .. ".\nCheck for any errors.")
      end

      -- Check if there are other sessions before destroying
      local session_count = session_manager.get_session_count()
      local current_bufnr = term_instance.buf

      -- Find the window currently displaying this terminal buffer
      -- (more reliable than stored win which might be stale)
      local current_winid = nil
      if current_bufnr and vim.api.nvim_buf_is_valid(current_bufnr) then
        local windows = vim.api.nvim_list_wins()
        for _, win in ipairs(windows) do
          if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == current_bufnr then
            current_winid = win
            break
          end
        end
      end
      -- Fallback to stored win if buffer not visible
      if not current_winid then
        current_winid = term_instance.win
      end

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
            -- Only destroy if session still exists (may have been destroyed by another handler)
            if session_manager.get_session(session.id) then
              session_manager.destroy_session(session.id)
            end
          end
        end
        -- Don't set terminal = nil yet, we might need it for fallback
      end

      vim.schedule(function()
        -- If there are other sessions, switch to the new active session instead of closing
        if session_count > 1 then
          local new_active_id = session_manager.get_active_session_id()
          if new_active_id then
            local new_term = terminals[new_active_id]

            -- Fallback 1: check if any other terminal in our table is valid
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

            -- Fallback 2: check the global terminal variable
            if not new_term or not new_term:buf_valid() then
              if terminal and terminal:buf_valid() and terminal ~= term_instance then
                new_term = terminal
                terminals[new_active_id] = new_term
                logger.debug("terminal", "Recovered global terminal for session: " .. new_active_id)
              end
            end

            -- Fallback 3: check session manager for terminal buffer and find matching terminal
            if not new_term or not new_term:buf_valid() then
              local session_data = session_manager.get_session(new_active_id)
              if
                session_data
                and session_data.terminal_bufnr
                and vim.api.nvim_buf_is_valid(session_data.terminal_bufnr)
              then
                -- Search all terminals for one with this buffer
                for _, term in pairs(terminals) do
                  if term and term:buf_valid() and term.buf == session_data.terminal_bufnr then
                    new_term = term
                    terminals[new_active_id] = new_term
                    logger.debug("terminal", "Recovered terminal by buffer for session: " .. new_active_id)
                    break
                  end
                end
                -- Also check global terminal
                if
                  (not new_term or not new_term:buf_valid())
                  and terminal
                  and terminal:buf_valid()
                  and terminal.buf == session_data.terminal_bufnr
                then
                  new_term = terminal
                  terminals[new_active_id] = new_term
                  logger.debug("terminal", "Recovered global terminal by buffer for session: " .. new_active_id)
                end
              end
            end

            if new_term and new_term:buf_valid() and new_term.buf then
              -- Keep the window open and switch to the other session's buffer
              if current_winid and vim.api.nvim_win_is_valid(current_winid) then
                -- Disconnect old terminal instance from this window
                -- (so it doesn't interfere when we delete its buffer)
                term_instance.win = nil

                -- Switch the window to show the new session's buffer
                vim.api.nvim_win_set_buf(current_winid, new_term.buf)
                new_term.win = current_winid

                -- Notify terminal of window dimensions
                local chan = vim.bo[new_term.buf].channel
                if chan and chan > 0 then
                  local width = vim.api.nvim_win_get_width(current_winid)
                  local height = vim.api.nvim_win_get_height(current_winid)
                  pcall(vim.fn.jobresize, chan, width, height)
                end

                -- Update legacy terminal reference
                terminal = new_term

                -- Focus and enter insert mode
                vim.api.nvim_set_current_win(current_winid)
                if vim.api.nvim_buf_get_option(new_term.buf, "buftype") == "terminal" then
                  vim.cmd("startinsert")
                end

                -- Re-attach tabbar
                local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
                if ok then
                  tabbar.attach(current_winid, new_term.buf, new_term)
                end

                logger.debug("terminal", "Switched to session " .. new_active_id .. " in same window")

                -- Delete the old buffer after switching (buffer is no longer displayed)
                if current_bufnr and vim.api.nvim_buf_is_valid(current_bufnr) then
                  vim.api.nvim_buf_delete(current_bufnr, { force = true })
                end

                vim.cmd.checktime()
                return
              else
                -- No valid window, show the other session using snacks toggle
                logger.debug("terminal", "No valid window, showing session " .. new_active_id)
                terminal = new_term
                new_term:toggle()
                if new_term.win and vim.api.nvim_win_is_valid(new_term.win) then
                  new_term:focus()
                  if new_term.buf and vim.api.nvim_buf_get_option(new_term.buf, "buftype") == "terminal" then
                    vim.api.nvim_win_call(new_term.win, function()
                      vim.cmd("startinsert")
                    end)
                  end
                end
                vim.cmd.checktime()
                return
              end
            end
          end
        end

        -- No other sessions or couldn't switch, close normally
        -- Clear terminal reference if this was the legacy terminal
        if terminal == term_instance then
          terminal = nil
        end
        term_instance:close({ buf = true })
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
      -- Destroy the session in session manager to prevent zombie sessions (only if it still exists)
      if session_manager.get_session(session_id) then
        session_manager.destroy_session(session_id)
      end
    else
      -- For legacy terminal, find and destroy associated session
      if term_instance.buf then
        local session = session_manager.find_session_by_bufnr(term_instance.buf)
        if session then
          logger.debug("terminal", "Destroying session for wiped terminal: " .. session.id)
          -- Only destroy if session still exists (may have been destroyed by TermClose)
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

---Builds Snacks terminal options with focus control
---@param config ClaudeCodeTerminalConfig Terminal configuration
---@param env_table table Environment variables to set for the terminal process
---@param focus boolean|nil Whether to focus the terminal when opened (defaults to true)
---@param session_id string|nil Optional session ID for title
---@return snacks.terminal.Opts opts Snacks terminal options with start_insert/auto_insert controlled by focus parameter
local function build_opts(config, env_table, focus, session_id)
  focus = utils.normalize_focus(focus)

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
  -- When smart ESC is enabled, we set up our own keymap after terminal creation
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

  -- Merge user's snacks_win_opts, preserving wo options for winbar support
  local win_opts = vim.tbl_deep_extend("force", {
    position = config.split_side,
    width = config.split_width_percentage,
    height = 0,
    relative = "editor",
    keys = keys,
    title = title,
    title_pos = title and "center" or nil,
    -- Don't clear winbar - we set it dynamically for session tabs
    wo = {},
  } --[[@as snacks.win.Config]], config.snacks_win_opts or {})

  return {
    env = env_table,
    cwd = config.cwd,
    start_insert = focus,
    auto_insert = focus,
    auto_close = false,
    win = win_opts,
  } --[[@as snacks.terminal.Opts]]
end

function M.setup()
  -- No specific setup needed for Snacks provider
end

---Open a terminal using Snacks.nvim
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
---@param focus boolean?
function M.open(cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  focus = utils.normalize_focus(focus)

  if terminal and terminal:buf_valid() then
    -- Check if terminal exists but is hidden (no window)
    if not terminal.win or not vim.api.nvim_win_is_valid(terminal.win) then
      -- Terminal is hidden, show it using snacks toggle
      terminal:toggle()
      if focus then
        terminal:focus()
        local term_buf_id = terminal.buf
        if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
          if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
            vim.api.nvim_win_call(terminal.win, function()
              vim.cmd("startinsert")
            end)
          end
        end
      end
    else
      -- Terminal is already visible
      if focus then
        terminal:focus()
        local term_buf_id = terminal.buf
        if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
          -- Check if window is valid before calling nvim_win_call
          if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
            vim.api.nvim_win_call(terminal.win, function()
              vim.cmd("startinsert")
            end)
          end
        end
      end
    end
    return
  end

  local opts = build_opts(config, env_table, focus)
  local term_instance = Snacks.terminal.open(cmd_string, opts)
  if term_instance and term_instance:buf_valid() then
    setup_terminal_events(term_instance, config)
    terminal = term_instance

    -- Set up smart ESC handling if enabled
    local terminal_module = require("claudecode.terminal")
    if config.esc_timeout and config.esc_timeout > 0 and term_instance.buf then
      terminal_module.setup_terminal_keymaps(term_instance.buf, config)
    end

    -- Ensure a session exists before attaching tabbar (session is needed for tabbar content)
    local session_id = session_manager.ensure_session()
    session_manager.update_terminal_info(session_id, {
      bufnr = term_instance.buf,
      winid = term_instance.win,
    })

    -- Attach tabbar directly with known window ID and snacks terminal instance
    -- Use vim.schedule to ensure snacks has finished its window setup
    if term_instance.win and vim.api.nvim_win_is_valid(term_instance.win) then
      local win_id = term_instance.win
      local buf_id = term_instance.buf
      local term_ref = term_instance
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win_id) then
          local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
          if ok then
            tabbar.attach(win_id, buf_id, term_ref)
          end
        end
      end)
    end
  else
    terminal = nil
    local logger = require("claudecode.logger")
    local error_details = {}
    if not term_instance then
      table.insert(error_details, "Snacks.terminal.open() returned nil")
    elseif not term_instance:buf_valid() then
      table.insert(error_details, "terminal instance is invalid")
      if term_instance.buf and not vim.api.nvim_buf_is_valid(term_instance.buf) then
        table.insert(error_details, "buffer is invalid")
      end
      if term_instance.win and not vim.api.nvim_win_is_valid(term_instance.win) then
        table.insert(error_details, "window is invalid")
      end
    end

    local context = string.format("cmd='%s', opts=%s", cmd_string, vim.inspect(opts))
    local error_msg = string.format(
      "Failed to open Claude terminal using Snacks. Details: %s. Context: %s",
      table.concat(error_details, ", "),
      context
    )
    vim.notify(error_msg, vim.log.levels.ERROR)
    logger.debug("terminal", error_msg)
  end
end

---Close the terminal
function M.close()
  if not is_available() then
    return
  end
  if terminal and terminal:buf_valid() then
    terminal:close()
  end
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

  local logger = require("claudecode.logger")

  -- Check if terminal exists and is visible
  if terminal and terminal:buf_valid() and terminal:win_valid() then
    -- Terminal is visible, hide it
    logger.debug("terminal", "Simple toggle: hiding visible terminal")
    terminal:toggle()
  elseif terminal and terminal:buf_valid() and not terminal:win_valid() then
    -- Terminal exists but not visible, show it
    logger.debug("terminal", "Simple toggle: showing hidden terminal")
    terminal:toggle()
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

  local logger = require("claudecode.logger")

  -- Terminal exists, is valid, but not visible
  if terminal and terminal:buf_valid() and not terminal:win_valid() then
    logger.debug("terminal", "Focus toggle: showing hidden terminal")
    terminal:toggle()
  -- Terminal exists, is valid, and is visible
  elseif terminal and terminal:buf_valid() and terminal:win_valid() then
    local claude_term_neovim_win_id = terminal.win
    local current_neovim_win_id = vim.api.nvim_get_current_win()

    -- you're IN it
    if claude_term_neovim_win_id == current_neovim_win_id then
      logger.debug("terminal", "Focus toggle: hiding terminal (currently focused)")
      terminal:toggle()
    -- you're NOT in it
    else
      logger.debug("terminal", "Focus toggle: focusing terminal")
      vim.api.nvim_set_current_win(claude_term_neovim_win_id)
      if terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
        if vim.api.nvim_buf_get_option(terminal.buf, "buftype") == "terminal" then
          vim.api.nvim_win_call(claude_term_neovim_win_id, function()
            vim.cmd("startinsert")
          end)
        end
      end
    end
  -- No terminal exists
  else
    logger.debug("terminal", "Focus toggle: creating new terminal")
    M.open(cmd_string, env_table, config)
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

---Hide all visible session terminals
---@param except_session_id string|nil Optional session ID to exclude from hiding
local function hide_all_session_terminals(except_session_id)
  for sid, term_instance in pairs(terminals) do
    if sid ~= except_session_id and term_instance and term_instance:buf_valid() then
      -- If terminal is visible, hide it
      if term_instance.win and vim.api.nvim_win_is_valid(term_instance.win) then
        term_instance:toggle()
      end
    end
  end

  -- Also hide the legacy terminal if it's different
  if terminal and terminal:buf_valid() then
    -- Check if legacy terminal is one of the session terminals
    local is_session_terminal = false
    for _, term_instance in pairs(terminals) do
      if term_instance == terminal then
        is_session_terminal = true
        break
      end
    end

    if not is_session_terminal and terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
      terminal:toggle()
    end
  end
end

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
  focus = utils.normalize_focus(focus)

  -- Check if this session already has a terminal
  local existing_term = terminals[session_id]
  if existing_term and existing_term:buf_valid() then
    -- Hide other session terminals first
    hide_all_session_terminals(session_id)

    -- Terminal exists, show/focus it
    if not existing_term.win or not vim.api.nvim_win_is_valid(existing_term.win) then
      existing_term:toggle()
    end
    if focus then
      existing_term:focus()
      local term_buf_id = existing_term.buf
      if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
        if existing_term.win and vim.api.nvim_win_is_valid(existing_term.win) then
          vim.api.nvim_win_call(existing_term.win, function()
            vim.cmd("startinsert")
          end)
        end
      end
    end
    return
  end

  -- Hide all other session terminals before creating new one
  hide_all_session_terminals(nil)

  -- Create new terminal for this session
  local opts = build_opts(config, env_table, focus, session_id)
  local term_instance = Snacks.terminal.open(cmd_string, opts)

  if term_instance and term_instance:buf_valid() then
    setup_terminal_events(term_instance, config, session_id)
    terminals[session_id] = term_instance

    -- Also set as legacy terminal for backward compatibility
    terminal = term_instance

    -- Update session manager with terminal info
    local terminal_module = require("claudecode.terminal")
    terminal_module.update_session_terminal_info(session_id, {
      bufnr = term_instance.buf,
      winid = term_instance.win,
    })

    -- Set up smart ESC handling if enabled
    if config.esc_timeout and config.esc_timeout > 0 and term_instance.buf then
      terminal_module.setup_terminal_keymaps(term_instance.buf, config)
    end

    -- Setup OSC title handler to capture terminal title changes
    if term_instance.buf then
      osc_handler.setup_buffer_handler(term_instance.buf, function(title)
        if title and title ~= "" then
          session_manager.update_session_name(session_id, title)
        end
      end)
    end

    -- Attach tabbar with snacks terminal instance for floating window title
    if term_instance.win and vim.api.nvim_win_is_valid(term_instance.win) then
      local win_id = term_instance.win
      local buf_id = term_instance.buf
      local term_ref = term_instance
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win_id) then
          local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
          if ok then
            tabbar.attach(win_id, buf_id, term_ref)
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
    term_instance:close({ buf = true })
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
  local old_term = terminals[old_session_id]
  local new_term = terminals[new_session_id]

  if not old_term then
    return
  end

  -- Mark as intentional close
  closing_sessions[old_session_id] = true

  -- Get the window from the old terminal
  local target_winid = old_term.win
  local had_visible_window = target_winid and vim.api.nvim_win_is_valid(target_winid)

  -- If new terminal exists, switch to it in the same window
  if new_term and new_term:buf_valid() then
    if had_visible_window and new_term.buf then
      -- Set the new buffer in the existing window
      vim.api.nvim_win_set_buf(target_winid, new_term.buf)
      new_term.win = target_winid

      -- Notify terminal of window dimensions
      local chan = vim.bo[new_term.buf].channel
      if chan and chan > 0 then
        local width = vim.api.nvim_win_get_width(target_winid)
        local height = vim.api.nvim_win_get_height(target_winid)
        pcall(vim.fn.jobresize, chan, width, height)
      end

      -- Focus and enter insert mode
      vim.api.nvim_set_current_win(target_winid)
      if vim.api.nvim_buf_get_option(new_term.buf, "buftype") == "terminal" then
        vim.cmd("startinsert")
      end

      -- Update tabbar
      local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
      if ok then
        tabbar.attach(target_winid, new_term.buf, new_term)
      end
    elseif not had_visible_window then
      -- Old window not visible, show new terminal
      new_term:toggle()
      if new_term.win and vim.api.nvim_win_is_valid(new_term.win) then
        new_term:focus()
        if new_term.buf and vim.api.nvim_buf_get_option(new_term.buf, "buftype") == "terminal" then
          vim.api.nvim_win_call(new_term.win, function()
            vim.cmd("startinsert")
          end)
        end
      end
    end

    -- Update legacy terminal reference
    terminal = new_term
  end

  -- Now close the old terminal's buffer (but window is already reused)
  if old_term:buf_valid() then
    -- Cleanup OSC handler
    if old_term.buf then
      osc_handler.cleanup_buffer_handler(old_term.buf)
    end
    -- Close just the buffer, not the window
    vim.api.nvim_buf_delete(old_term.buf, { force = true })
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
  local term_instance = terminals[session_id]

  -- If not found in terminals table, try fallback to legacy terminal
  if not term_instance or not term_instance:buf_valid() then
    -- Check if legacy terminal matches the session's bufnr from session_manager
    local session_mod = require("claudecode.session")
    local session = session_mod.get_session(session_id)
    if
      session
      and session.terminal_bufnr
      and terminal
      and terminal:buf_valid()
      and terminal.buf == session.terminal_bufnr
    then
      -- Legacy terminal matches this session, register it now
      logger.debug("terminal", "Registering legacy terminal for session: " .. session_id)
      M.register_terminal_for_session(session_id, terminal.buf)
      term_instance = terminals[session_id]
    end

    if not term_instance or not term_instance:buf_valid() then
      logger.debug("terminal", "Cannot focus invalid session: " .. session_id)
      return
    end
  end

  -- Hide other session terminals first
  hide_all_session_terminals(session_id)

  -- If terminal is hidden, show it
  if not term_instance.win or not vim.api.nvim_win_is_valid(term_instance.win) then
    term_instance:toggle()
  end

  -- Focus the terminal
  term_instance:focus()
  local term_buf_id = term_instance.buf
  if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
    if term_instance.win and vim.api.nvim_win_is_valid(term_instance.win) then
      -- Notify terminal of window dimensions to fix cursor position after session switch
      local chan = vim.bo[term_buf_id].channel
      if chan and chan > 0 then
        local width = vim.api.nvim_win_get_width(term_instance.win)
        local height = vim.api.nvim_win_get_height(term_instance.win)
        pcall(vim.fn.jobresize, chan, width, height)
      end

      vim.api.nvim_win_call(term_instance.win, function()
        vim.cmd("startinsert")
      end)
    end
  end

  -- Update tabbar with the new terminal instance
  if term_instance.win and vim.api.nvim_win_is_valid(term_instance.win) then
    local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
    if ok then
      tabbar.attach(term_instance.win, term_instance.buf, term_instance)
    end
  end
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
---This is called when a terminal was created via simple_toggle/focus_toggle
---and we need to associate it with a session for multi-session support.
---@param session_id string The session ID
---@param term_bufnr number|nil The buffer number (uses legacy terminal's bufnr if nil)
function M.register_terminal_for_session(session_id, term_bufnr)
  local logger = require("claudecode.logger")

  -- If no bufnr provided, use the legacy terminal
  if not term_bufnr and terminal and terminal:buf_valid() then
    term_bufnr = terminal.buf
  end

  if not term_bufnr then
    logger.debug("terminal", "Cannot register nil terminal for session: " .. session_id)
    return
  end

  -- Check if this terminal is already registered to another session
  for sid, term_instance in pairs(terminals) do
    if term_instance and term_instance:buf_valid() and term_instance.buf == term_bufnr and sid ~= session_id then
      -- Already registered to a different session, skip
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
