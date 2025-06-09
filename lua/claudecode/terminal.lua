--- Module to manage a dedicated vertical split terminal for Claude Code.
-- Supports Snacks.nvim or a native Neovim terminal fallback.
-- @module claudecode.terminal
-- @plugin snacks.nvim (optional)

local M = {}

local snacks_available, Snacks = pcall(require, "snacks")
if not snacks_available then
  Snacks = nil
  vim.notify(
    "Snacks.nvim not found. ClaudeCode will use built-in Neovim terminal if configured or as fallback.",
    vim.log.levels.INFO
  )
end

local claudecode_server_module = require("claudecode.server.init")

local term_module_config = {
  split_side = "right",
  split_width_percentage = 0.30,
  provider = "snacks",
  show_native_term_exit_tip = true,
  terminal_cmd = nil, -- Will be set by setup() from main config
}

--- State to keep track of the managed Claude terminal instance (from Snacks).
-- @type table|nil #snacks_terminal_instance The Snacks terminal instance, or nil if not active.
local managed_snacks_terminal = nil

local managed_fallback_terminal_bufnr = nil
local managed_fallback_terminal_winid = nil
local managed_fallback_terminal_jobid = nil
local native_term_tip_shown = false

-- Uses the `terminal_cmd` from the module's configuration, or defaults to "claude".
-- @param cmd_args string|nil Optional arguments to append to the command
-- @return string The command to execute.
local function get_claude_command(cmd_args)
  local cmd_from_config = term_module_config.terminal_cmd
  local base_cmd
  if not cmd_from_config or cmd_from_config == "" then
    base_cmd = "claude" -- Default if not configured
  else
    base_cmd = cmd_from_config
  end

  if cmd_args and cmd_args ~= "" then
    return base_cmd .. " " .. cmd_args
  end
  return base_cmd
end

--- Configures the terminal module.
-- Merges user-provided terminal configuration with defaults and sets the terminal command.
-- @param user_term_config table (optional) Configuration options for the terminal.
-- @field user_term_config.split_side string 'left' or 'right' (default: 'right').
-- @field user_term_config.split_width_percentage number Percentage of screen width (0.0 to 1.0, default: 0.30).
-- @field user_term_config.provider string 'snacks' or 'native' (default: 'snacks').
-- @field user_term_config.show_native_term_exit_tip boolean Show tip for exiting native terminal (default: true).
-- @param p_terminal_cmd string|nil The command to run in the terminal (from main config).
function M.setup(user_term_config, p_terminal_cmd)
  if user_term_config == nil then -- Allow nil, default to empty table silently
    user_term_config = {}
  elseif type(user_term_config) ~= "table" then -- Warn if it's not nil AND not a table
    vim.notify("claudecode.terminal.setup expects a table or nil for user_term_config", vim.log.levels.WARN)
    user_term_config = {}
  end

  if p_terminal_cmd == nil or type(p_terminal_cmd) == "string" then
    term_module_config.terminal_cmd = p_terminal_cmd
  else
    vim.notify(
      "claudecode.terminal.setup: Invalid terminal_cmd provided: " .. tostring(p_terminal_cmd) .. ". Using default.",
      vim.log.levels.WARN
    )
    term_module_config.terminal_cmd = nil -- Fallback to default behavior in get_claude_command
  end

  for k, v in pairs(user_term_config) do
    if term_module_config[k] ~= nil and k ~= "terminal_cmd" then -- terminal_cmd is handled above
      if k == "split_side" and (v == "left" or v == "right") then
        term_module_config[k] = v
      elseif k == "split_width_percentage" and type(v) == "number" and v > 0 and v < 1 then
        term_module_config[k] = v
      elseif k == "provider" and (v == "snacks" or v == "native") then
        term_module_config[k] = v
      elseif k == "show_native_term_exit_tip" and type(v) == "boolean" then
        term_module_config[k] = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for " .. k .. ": " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k ~= "terminal_cmd" then -- Avoid warning for terminal_cmd if passed in user_term_config
      vim.notify("claudecode.terminal.setup: Unknown configuration key: " .. k, vim.log.levels.WARN)
    end
  end
end

--- Determines the effective terminal provider based on configuration and availability.
-- @return string "snacks" or "native"
local function get_effective_terminal_provider()
  if term_module_config.provider == "snacks" then
    if snacks_available then
      return "snacks"
    else
      vim.notify(
        "ClaudeCode: 'snacks' provider configured, but Snacks.nvim not available. Falling back to 'native'.",
        vim.log.levels.WARN
      )
      return "native"
    end
  elseif term_module_config.provider == "native" then
    return "native"
  else
    vim.notify(
      "ClaudeCode: Invalid provider configured: "
        .. tostring(term_module_config.provider)
        .. ". Defaulting to 'native'.",
      vim.log.levels.WARN
    )
    return "native" -- Default to native if misconfigured
  end
end

local function cleanup_fallback_terminal_state()
  managed_fallback_terminal_bufnr = nil
  managed_fallback_terminal_winid = nil
  managed_fallback_terminal_jobid = nil
end

--- Checks if the managed fallback terminal is currently valid (window and buffer exist).
-- Cleans up state if invalid.
-- @return boolean True if valid, false otherwise.
local function is_fallback_terminal_valid()
  -- First check if we have a valid buffer
  if not managed_fallback_terminal_bufnr or not vim.api.nvim_buf_is_valid(managed_fallback_terminal_bufnr) then
    cleanup_fallback_terminal_state()
    return false
  end

  -- If buffer is valid but window is invalid, try to find a window displaying this buffer
  if not managed_fallback_terminal_winid or not vim.api.nvim_win_is_valid(managed_fallback_terminal_winid) then
    -- Search all windows for our terminal buffer
    local windows = vim.api.nvim_list_wins()
    for _, win in ipairs(windows) do
      if vim.api.nvim_win_get_buf(win) == managed_fallback_terminal_bufnr then
        -- Found a window displaying our terminal buffer, update the tracked window ID
        managed_fallback_terminal_winid = win
        require("claudecode.logger").debug("terminal", "Recovered terminal window ID:", win)
        return true
      end
    end
    -- Buffer exists but no window displays it
    cleanup_fallback_terminal_state()
    return false
  end

  -- Both buffer and window are valid
  return true
end

--- Opens a new terminal using native Neovim functions.
-- @param cmd_string string The command string to run.
-- @param env_table table Environment variables for the command.
-- @param effective_term_config table Configuration for split_side and split_width_percentage.
-- @return boolean True if successful, false otherwise.
local function open_fallback_terminal(cmd_string, env_table, effective_term_config)
  if is_fallback_terminal_valid() then -- Should not happen if called correctly, but as a safeguard
    vim.api.nvim_set_current_win(managed_fallback_terminal_winid)
    vim.cmd("startinsert")
    return true
  end

  local original_win = vim.api.nvim_get_current_win()

  local width = math.floor(vim.o.columns * effective_term_config.split_width_percentage)
  local full_height = vim.o.lines
  local placement_modifier

  if effective_term_config.split_side == "left" then
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
  -- Note: vim.api.nvim_win_set_width is not needed here again as [N]vsplit handles it.

  local term_cmd_arg
  if cmd_string:find(" ", 1, true) then
    term_cmd_arg = vim.split(cmd_string, " ", { plain = true, trimempty = false })
  else
    term_cmd_arg = { cmd_string }
  end

  managed_fallback_terminal_jobid = vim.fn.termopen(term_cmd_arg, {
    env = env_table,
    on_exit = function(job_id, _, _)
      vim.schedule(function()
        if job_id == managed_fallback_terminal_jobid then
          -- Ensure we are operating on the correct window and buffer before closing
          local current_winid_for_job = managed_fallback_terminal_winid
          local current_bufnr_for_job = managed_fallback_terminal_bufnr

          cleanup_fallback_terminal_state() -- Clear our managed state first

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

  if not managed_fallback_terminal_jobid or managed_fallback_terminal_jobid == 0 then
    vim.notify("Failed to open native terminal.", vim.log.levels.ERROR)
    vim.api.nvim_win_close(new_winid, true)
    vim.api.nvim_set_current_win(original_win)
    cleanup_fallback_terminal_state()
    return false
  end

  managed_fallback_terminal_winid = new_winid
  managed_fallback_terminal_bufnr = vim.api.nvim_get_current_buf()
  vim.bo[managed_fallback_terminal_bufnr].bufhidden = "wipe" -- Wipe buffer when hidden (e.g., window closed)
  -- buftype=terminal is set by termopen

  vim.api.nvim_set_current_win(managed_fallback_terminal_winid)
  vim.cmd("startinsert")

  if term_module_config.show_native_term_exit_tip and not native_term_tip_shown then
    vim.notify("Native terminal opened. Press Ctrl-\\ Ctrl-N to return to Normal mode.", vim.log.levels.INFO)
    native_term_tip_shown = true
  end
  return true
end

--- Closes the managed fallback terminal if it's open and valid.
local function close_fallback_terminal()
  if is_fallback_terminal_valid() then
    -- Closing the window should trigger on_exit of the job if the process is still running,
    -- which then calls cleanup_fallback_terminal_state.
    -- If the job already exited, on_exit would have cleaned up.
    -- This direct close is for user-initiated close.
    vim.api.nvim_win_close(managed_fallback_terminal_winid, true)
    cleanup_fallback_terminal_state() -- Ensure cleanup if on_exit doesn't fire (e.g. job already dead)
  end
end

--- Focuses the managed fallback terminal if it's open and valid.
local function focus_fallback_terminal()
  if is_fallback_terminal_valid() then
    vim.api.nvim_set_current_win(managed_fallback_terminal_winid)
    vim.cmd("startinsert")
  end
end

--- Builds the effective terminal configuration by merging module defaults with runtime overrides.
-- Used by the native fallback.
-- @param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
-- @return table The effective terminal configuration.
local function build_effective_term_config(opts_override)
  local effective_config = vim.deepcopy(term_module_config)
  if type(opts_override) == "table" then
    local validators = {
      split_side = function(val)
        return val == "left" or val == "right"
      end,
      split_width_percentage = function(val)
        return type(val) == "number" and val > 0 and val < 1
      end,
    }
    for key, val in pairs(opts_override) do
      if effective_config[key] ~= nil and validators[key] and validators[key](val) then
        effective_config[key] = val
      end
    end
  end
  return {
    split_side = effective_config.split_side,
    split_width_percentage = effective_config.split_width_percentage,
  }
end

--- Builds the options table for Snacks.terminal.
-- This function merges the module's current terminal configuration
-- with any runtime overrides provided specifically for an open/toggle action.
-- @param effective_term_config_for_snacks table Pre-calculated effective config for split_side, width.
-- @param env_table table Environment variables for the command.
-- @return table The options table for Snacks.
local function build_snacks_opts(effective_term_config_for_snacks, env_table)
  return {
    -- cmd is passed as the first argument to Snacks.terminal.open/toggle
    env = env_table,
    interactive = true, -- for auto_close and start_insert
    enter = true, -- focus the terminal when opened
    win = {
      position = effective_term_config_for_snacks.split_side,
      width = effective_term_config_for_snacks.split_width_percentage, -- snacks.win uses <1 for relative width
      height = 0, -- 0 for full height in snacks.win
      relative = "editor",
      on_close = function(self) -- self here is the snacks.win instance
        if managed_snacks_terminal and managed_snacks_terminal.win == self.win then
          managed_snacks_terminal = nil
        end
      end,
    },
  }
end

--- Gets the base claude command string and necessary environment variables.
-- @param cmd_args string|nil Optional arguments to append to the command
-- @return string|nil cmd_string The command string, or nil on failure.
-- @return table|nil env_table The environment variables table, or nil on failure.
local function get_claude_command_and_env(cmd_args)
  local cmd_string = get_claude_command(cmd_args)
  if not cmd_string or cmd_string == "" then
    vim.notify("Claude terminal base command cannot be determined.", vim.log.levels.ERROR)
    return nil, nil
  end

  -- cmd_string is returned as is; splitting will be handled by consumer if needed (e.g., for native termopen)

  local sse_port_value = claudecode_server_module.state.port
  local env_table = {
    ENABLE_IDE_INTEGRATION = "true",
    FORCE_CODE_TERMINAL = "true",
  }

  if sse_port_value then
    env_table["CLAUDE_CODE_SSE_PORT"] = tostring(sse_port_value)
  end

  return cmd_string, env_table
end

--- Find any existing Claude Code terminal buffer by checking terminal job command
-- @return number|nil Buffer number if found, nil otherwise
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
            require("claudecode.logger").debug(
              "terminal",
              "Found existing Claude terminal in buffer",
              buf,
              "window",
              win
            )
            return buf, win
          end
        end
      end
    end
  end
  return nil, nil
end

--- Opens or focuses the Claude terminal.
-- @param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
-- @param cmd_args string|nil (optional) Arguments to append to the claude command.
function M.open(opts_override, cmd_args)
  local provider = get_effective_terminal_provider()
  local effective_config = build_effective_term_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  if not cmd_string then
    -- Error already notified by the helper function
    return
  end

  if provider == "snacks" then
    if not Snacks or not Snacks.terminal then -- Should be caught by snacks_available, but defensive
      vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
      return
    end
    if managed_snacks_terminal and managed_snacks_terminal:valid() then
      managed_snacks_terminal:focus()
      local term_buf_id = managed_snacks_terminal.buf
      if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
        vim.api.nvim_win_call(managed_snacks_terminal.win, function()
          vim.cmd("startinsert")
        end)
      end
      return
    end
    local snacks_opts = build_snacks_opts(effective_config, claude_env_table)
    local term_instance = Snacks.terminal.open(cmd_string, snacks_opts)
    if term_instance and term_instance:valid() then
      managed_snacks_terminal = term_instance
    else
      vim.notify("Failed to open Claude terminal using Snacks.", vim.log.levels.ERROR)
      managed_snacks_terminal = nil
    end
  elseif provider == "native" then
    if is_fallback_terminal_valid() then
      focus_fallback_terminal()
    else
      -- Check if there's an existing Claude terminal we lost track of
      local existing_buf, existing_win = find_existing_claude_terminal()
      if existing_buf and existing_win then
        -- Recover the existing terminal
        managed_fallback_terminal_bufnr = existing_buf
        managed_fallback_terminal_winid = existing_win
        -- Note: We can't recover the job ID easily, but it's less critical
        require("claudecode.logger").debug("terminal", "Recovered existing Claude terminal")
        focus_fallback_terminal()
      else
        if not open_fallback_terminal(cmd_string, claude_env_table, effective_config) then
          vim.notify("Failed to open Claude terminal using native fallback.", vim.log.levels.ERROR)
        end
      end
    end
  end
end

--- Closes the managed Claude terminal if it's open and valid.
function M.close()
  local provider = get_effective_terminal_provider()
  if provider == "snacks" then
    if not Snacks or not Snacks.terminal then
      return
    end -- Defensive
    if managed_snacks_terminal and managed_snacks_terminal:valid() then
      managed_snacks_terminal:close()
      -- managed_snacks_terminal will be set to nil by the on_close callback
    end
  elseif provider == "native" then
    close_fallback_terminal()
  end
end

--- Toggles the Claude terminal open or closed.
-- @param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
-- @param cmd_args string|nil (optional) Arguments to append to the claude command.
function M.toggle(opts_override, cmd_args)
  local provider = get_effective_terminal_provider()
  local effective_config = build_effective_term_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  if not cmd_string then
    return -- Error already notified
  end

  if provider == "snacks" then
    if not Snacks or not Snacks.terminal then
      vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
      return
    end
    local snacks_opts = build_snacks_opts(effective_config, claude_env_table)

    if managed_snacks_terminal and managed_snacks_terminal:valid() and managed_snacks_terminal.win then
      local claude_term_neovim_win_id = managed_snacks_terminal.win
      local current_neovim_win_id = vim.api.nvim_get_current_win()

      if claude_term_neovim_win_id == current_neovim_win_id then
        -- Snacks.terminal.toggle will return an invalid instance or nil.
        -- The on_close callback (defined in build_snacks_opts) will set managed_snacks_terminal to nil.
        local closed_instance = Snacks.terminal.toggle(cmd_string, snacks_opts)
        if closed_instance and closed_instance:valid() then
          -- This would be unexpected if it was supposed to close and on_close fired.
          -- As a fallback, ensure our state reflects what Snacks returned if it's somehow still valid.
          managed_snacks_terminal = closed_instance
        end
      else
        vim.api.nvim_set_current_win(claude_term_neovim_win_id)
        if managed_snacks_terminal.buf and vim.api.nvim_buf_is_valid(managed_snacks_terminal.buf) then
          if vim.api.nvim_buf_get_option(managed_snacks_terminal.buf, "buftype") == "terminal" then
            vim.api.nvim_win_call(claude_term_neovim_win_id, function()
              vim.cmd("startinsert")
            end)
          end
        end
      end
    else
      local term_instance = Snacks.terminal.toggle(cmd_string, snacks_opts)
      if term_instance and term_instance:valid() and term_instance.win then
        managed_snacks_terminal = term_instance
      else
        managed_snacks_terminal = nil
        if not (term_instance == nil and managed_snacks_terminal == nil) then -- Avoid notify if toggle returned nil and we set to nil
          vim.notify("Failed to open Snacks terminal or instance invalid after toggle.", vim.log.levels.WARN)
        end
      end
    end
  elseif provider == "native" then
    if is_fallback_terminal_valid() then
      local claude_term_neovim_win_id = managed_fallback_terminal_winid
      local current_neovim_win_id = vim.api.nvim_get_current_win()

      if claude_term_neovim_win_id == current_neovim_win_id then
        close_fallback_terminal()
      else
        focus_fallback_terminal() -- This already calls startinsert
      end
    else
      -- Check if there's an existing Claude terminal we lost track of
      local existing_buf, existing_win = find_existing_claude_terminal()
      if existing_buf and existing_win then
        -- Recover the existing terminal
        managed_fallback_terminal_bufnr = existing_buf
        managed_fallback_terminal_winid = existing_win
        require("claudecode.logger").debug("terminal", "Recovered existing Claude terminal in toggle")

        -- Check if we're currently in this terminal
        local current_neovim_win_id = vim.api.nvim_get_current_win()
        if existing_win == current_neovim_win_id then
          close_fallback_terminal()
        else
          focus_fallback_terminal()
        end
      else
        if not open_fallback_terminal(cmd_string, claude_env_table, effective_config) then
          vim.notify("Failed to open Claude terminal using native fallback (toggle).", vim.log.levels.ERROR)
        end
      end
    end
  end
end

--- Gets the managed terminal instance for testing purposes.
-- NOTE: This function is intended for use in tests to inspect internal state.
-- The underscore prefix indicates it's not part of the public API for regular use.
-- @return table|nil The managed Snacks terminal instance, or nil.
function M._get_managed_terminal_for_test()
  return managed_snacks_terminal
end

--- Gets the buffer number of the currently active Claude Code terminal.
-- This checks both Snacks and native fallback terminals.
-- @return number|nil The buffer number if an active terminal is found, otherwise nil.
function M.get_active_terminal_bufnr()
  if managed_snacks_terminal and managed_snacks_terminal:valid() and managed_snacks_terminal.buf then
    if vim.api.nvim_buf_is_valid(managed_snacks_terminal.buf) then
      return managed_snacks_terminal.buf
    end
  end

  if is_fallback_terminal_valid() then
    return managed_fallback_terminal_bufnr
  end

  return nil
end

return M
