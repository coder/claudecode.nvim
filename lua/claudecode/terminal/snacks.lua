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
      if vim.v.event.status ~= 0 then
        logger.error("terminal", "Claude exited with code " .. vim.v.event.status .. ".\nCheck for any errors.")
      end

      -- Clean up
      if session_id then
        terminals[session_id] = nil
      else
        terminal = nil
      end
      vim.schedule(function()
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
    else
      terminal = nil
    end
  end, { buf = true })
end

---Builds Snacks terminal options with focus control
---@param config ClaudeCodeTerminalConfig Terminal configuration
---@param env_table table Environment variables to set for the terminal process
---@param focus boolean|nil Whether to focus the terminal when opened (defaults to true)
---@return snacks.terminal.Opts opts Snacks terminal options with start_insert/auto_insert controlled by focus parameter
local function build_opts(config, env_table, focus)
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

  return {
    env = env_table,
    cwd = config.cwd,
    start_insert = focus,
    auto_insert = focus,
    auto_close = false,
    win = vim.tbl_deep_extend("force", {
      position = config.split_side,
      width = config.split_width_percentage,
      height = 0,
      relative = "editor",
      keys = keys,
    } --[[@as snacks.win.Config]], config.snacks_win_opts or {}),
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
    if config.esc_timeout and config.esc_timeout > 0 and term_instance.buf then
      local terminal_module = require("claudecode.terminal")
      terminal_module.setup_terminal_keymaps(term_instance.buf, config)
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
  local opts = build_opts(config, env_table, focus)
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
    term_instance:close({ buf = true })
    terminals[session_id] = nil

    -- If this was the legacy terminal, clear it too
    if terminal == term_instance then
      terminal = nil
    end
  end
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
