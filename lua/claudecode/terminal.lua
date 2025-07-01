--- Module to manage a dedicated vertical split terminal for Claude Code.
-- Supports Snacks.nvim or a native Neovim terminal fallback.
-- @module claudecode.terminal

--- @class TerminalProvider
--- @field setup function
--- @field open function
--- @field close function
--- @field toggle function
--- @field simple_toggle function
--- @field focus_toggle function
--- @field get_active_bufnr function
--- @field is_available function
--- @field _get_terminal_for_test function

local M = {}

local claudecode_server_module = require("claudecode.server.init")

local config = {
  split_side = "right",
  split_width_percentage = 0.30,
  provider = "auto",
  show_native_term_exit_tip = true,
  terminal_cmd = nil,
  auto_close = true,
}

-- Lazy load providers
local providers = {}

--- Loads a terminal provider module
--- @param provider_name string The name of the provider to load
--- @return TerminalProvider|nil provider The provider module, or nil if loading failed
local function load_provider(provider_name)
  if not providers[provider_name] then
    local ok, provider = pcall(require, "claudecode.terminal." .. provider_name)
    if ok then
      providers[provider_name] = provider
    else
      return nil
    end
  end
  return providers[provider_name]
end

--- Gets the effective terminal provider, guaranteed to return a valid provider
--- Falls back to native provider if configured provider is unavailable
--- @return TerminalProvider provider The terminal provider module (never nil)
local function get_provider()
  local logger = require("claudecode.logger")

  if config.provider == "auto" then
    -- Try snacks first, then fallback to native silently
    local snacks_provider = load_provider("snacks")
    if snacks_provider and snacks_provider.is_available() then
      return snacks_provider
    end
    -- Fall through to native provider
  elseif config.provider == "snacks" then
    local snacks_provider = load_provider("snacks")
    if snacks_provider and snacks_provider.is_available() then
      return snacks_provider
    else
      logger.warn("terminal", "'snacks' provider configured, but Snacks.nvim not available. Falling back to 'native'.")
    end
  elseif config.provider == "native" then
    -- noop, will use native provider as default below
    logger.debug("terminal", "Using native terminal provider")
  else
    logger.warn("terminal", "Invalid provider configured: " .. tostring(config.provider) .. ". Defaulting to 'native'.")
  end

  local native_provider = load_provider("native")
  if not native_provider then
    error("ClaudeCode: Critical error - native terminal provider failed to load")
  end
  return native_provider
end

--- Builds the effective terminal configuration by merging defaults with overrides
--- @param opts_override table|nil Optional overrides for terminal appearance
--- @return table The effective terminal configuration
local function build_config(opts_override)
  local effective_config = vim.deepcopy(config)
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
    auto_close = effective_config.auto_close,
  }
end

--- Checks if a terminal buffer is currently visible in any window
--- @param bufnr number|nil The buffer number to check
--- @return boolean True if the buffer is visible in any window, false otherwise
local function is_terminal_visible(bufnr)
  if not bufnr then
    return false
  end

  local bufinfo = vim.fn.getbufinfo(bufnr)
  return bufinfo and #bufinfo > 0 and #bufinfo[1].windows > 0
end

--- Gets the claude command string and necessary environment variables
--- @param cmd_args string|nil Optional arguments to append to the command
--- @return string cmd_string The command string
--- @return table env_table The environment variables table
local function get_claude_command_and_env(cmd_args)
  -- Inline get_claude_command logic
  local cmd_from_config = config.terminal_cmd
  local base_cmd
  if not cmd_from_config or cmd_from_config == "" then
    base_cmd = "claude" -- Default if not configured
  else
    base_cmd = cmd_from_config
  end

  local cmd_string
  if cmd_args and cmd_args ~= "" then
    cmd_string = base_cmd .. " " .. cmd_args
  else
    cmd_string = base_cmd
  end

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

--- Common helper to open terminal without focus if not already visible
--- @param opts_override table|nil Optional config overrides
--- @param cmd_args string|nil Optional command arguments
--- @return boolean True if terminal was opened or already visible
local function ensure_terminal_visible_no_focus(opts_override, cmd_args)
  local provider = get_provider()
  local active_bufnr = provider.get_active_bufnr()

  if is_terminal_visible(active_bufnr) then
    -- Terminal is already visible, do nothing
    return true
  end

  -- Terminal is not visible, open it without focus
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  provider.open(cmd_string, claude_env_table, effective_config, false) -- false = don't focus
  return true
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
    config.terminal_cmd = p_terminal_cmd
  else
    vim.notify(
      "claudecode.terminal.setup: Invalid terminal_cmd provided: " .. tostring(p_terminal_cmd) .. ". Using default.",
      vim.log.levels.WARN
    )
    config.terminal_cmd = nil -- Fallback to default behavior
  end

  for k, v in pairs(user_term_config) do
    if config[k] ~= nil and k ~= "terminal_cmd" then -- terminal_cmd is handled above
      if k == "split_side" and (v == "left" or v == "right") then
        config[k] = v
      elseif k == "split_width_percentage" and type(v) == "number" and v > 0 and v < 1 then
        config[k] = v
      elseif k == "provider" and (v == "snacks" or v == "native") then
        config[k] = v
      elseif k == "show_native_term_exit_tip" and type(v) == "boolean" then
        config[k] = v
      elseif k == "auto_close" and type(v) == "boolean" then
        config[k] = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for " .. k .. ": " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k ~= "terminal_cmd" then -- Avoid warning for terminal_cmd if passed in user_term_config
      vim.notify("claudecode.terminal.setup: Unknown configuration key: " .. k, vim.log.levels.WARN)
    end
  end

  -- Setup providers with config
  get_provider().setup(config)
end

--- Opens or focuses the Claude terminal.
-- @param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
-- @param cmd_args string|nil (optional) Arguments to append to the claude command.
function M.open(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  get_provider().open(cmd_string, claude_env_table, effective_config)
end

--- Closes the managed Claude terminal if it's open and valid.
function M.close()
  get_provider().close()
end

--- Simple toggle: always show/hide the Claude terminal regardless of focus.
-- @param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
-- @param cmd_args string|nil (optional) Arguments to append to the claude command.
function M.simple_toggle(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  get_provider().simple_toggle(cmd_string, claude_env_table, effective_config)
end

--- Smart focus toggle: switches to terminal if not focused, hides if currently focused.
-- @param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
-- @param cmd_args string|nil (optional) Arguments to append to the claude command.
function M.focus_toggle(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  get_provider().focus_toggle(cmd_string, claude_env_table, effective_config)
end

--- Toggle open terminal without focus if not already visible, otherwise do nothing.
-- @param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
-- @param cmd_args string|nil (optional) Arguments to append to the claude command.
function M.toggle_open_no_focus(opts_override, cmd_args)
  ensure_terminal_visible_no_focus(opts_override, cmd_args)
end

--- Ensures terminal is visible without changing focus. Creates if necessary, shows if hidden.
-- @param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
-- @param cmd_args string|nil (optional) Arguments to append to the claude command.
function M.ensure_visible(opts_override, cmd_args)
  ensure_terminal_visible_no_focus(opts_override, cmd_args)
end

--- Toggles the Claude terminal open or closed (legacy function - use simple_toggle or focus_toggle).
-- @param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
-- @param cmd_args string|nil (optional) Arguments to append to the claude command.
function M.toggle(opts_override, cmd_args)
  -- Default to simple toggle for backward compatibility
  M.simple_toggle(opts_override, cmd_args)
end

--- Gets the buffer number of the currently active Claude Code terminal.
-- This checks both Snacks and native fallback terminals.
-- @return number|nil The buffer number if an active terminal is found, otherwise nil.
function M.get_active_terminal_bufnr()
  return get_provider().get_active_bufnr()
end

--- Gets the managed terminal instance for testing purposes.
-- NOTE: This function is intended for use in tests to inspect internal state.
-- The underscore prefix indicates it's not part of the public API for regular use.
-- @return snacks.terminal|nil The managed Snacks terminal instance, or nil.
function M._get_managed_terminal_for_test()
  local snacks_provider = load_provider("snacks")
  if snacks_provider and snacks_provider._get_terminal_for_test then
    return snacks_provider._get_terminal_for_test()
  end
  return nil
end

return M
