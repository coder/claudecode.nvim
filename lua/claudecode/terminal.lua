--- Module to manage a dedicated vertical split terminal for Claude Code.
--- Supports Snacks.nvim or a native Neovim terminal fallback.
--- @module 'claudecode.terminal'

local M = {}

local claudecode_server_module = require("claudecode.server.init")

---@type ClaudeCodeTerminalConfig
local defaults = {
  split_side = "right",
  split_width_percentage = 0.30,
  provider = "auto",
  show_native_term_exit_tip = true,
  terminal_cmd = nil,
  provider_opts = {
    external_terminal_cmd = nil,
  },
  auto_close = true,
  env = {},
  snacks_win_opts = {},
  -- Working directory control
  cwd = nil, -- static cwd override
  git_repo_cwd = false, -- resolve to git root when spawning
  cwd_provider = nil, -- function(ctx) -> cwd string
}

M.defaults = defaults

-- Lazy load providers
local providers = {}

---Loads a terminal provider module
---@param provider_name string The name of the provider to load
---@return ClaudeCodeTerminalProvider? provider The provider module, or nil if loading failed
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

---Validates and enhances a custom table provider with smart defaults
---@param provider ClaudeCodeTerminalProvider The custom provider table to validate
---@return ClaudeCodeTerminalProvider? provider The enhanced provider, or nil if invalid
---@return string? error Error message if validation failed
local function validate_and_enhance_provider(provider)
  if type(provider) ~= "table" then
    return nil, "Custom provider must be a table"
  end

  -- Required functions that must be implemented
  local required_functions = {
    "setup",
    "open",
    "close",
    "simple_toggle",
    "focus_toggle",
    "get_active_bufnr",
    "is_available",
  }

  -- Validate all required functions exist and are callable
  for _, func_name in ipairs(required_functions) do
    local func = provider[func_name]
    if not func then
      return nil, "Custom provider missing required function: " .. func_name
    end
    -- Check if it's callable (function or table with __call metamethod)
    local is_callable = type(func) == "function"
      or (type(func) == "table" and getmetatable(func) and getmetatable(func).__call)
    if not is_callable then
      return nil, "Custom provider field '" .. func_name .. "' must be callable, got: " .. type(func)
    end
  end

  -- Create enhanced provider with defaults for optional functions
  -- Note: Don't deep copy to preserve spy functions in tests
  local enhanced_provider = provider

  -- Add default toggle function if not provided (calls simple_toggle for backward compatibility)
  if not enhanced_provider.toggle then
    enhanced_provider.toggle = function(cmd_string, env_table, effective_config)
      return enhanced_provider.simple_toggle(cmd_string, env_table, effective_config)
    end
  end

  -- Add default test function if not provided
  if not enhanced_provider._get_terminal_for_test then
    enhanced_provider._get_terminal_for_test = function()
      return nil
    end
  end

  return enhanced_provider, nil
end

---Gets the effective terminal provider, guaranteed to return a valid provider
---Falls back to native provider if configured provider is unavailable
---@return ClaudeCodeTerminalProvider provider The terminal provider module (never nil)
local function get_provider()
  local logger = require("claudecode.logger")

  -- Handle custom table provider
  if type(defaults.provider) == "table" then
    local custom_provider = defaults.provider --[[@as ClaudeCodeTerminalProvider]]
    local enhanced_provider, error_msg = validate_and_enhance_provider(custom_provider)
    if enhanced_provider then
      -- Check if custom provider is available
      local is_available_ok, is_available = pcall(enhanced_provider.is_available)
      if is_available_ok and is_available then
        logger.debug("terminal", "Using custom table provider")
        return enhanced_provider
      else
        local availability_msg = is_available_ok and "provider reports not available" or "error checking availability"
        logger.warn(
          "terminal",
          "Custom table provider configured but " .. availability_msg .. ". Falling back to 'native'."
        )
      end
    else
      logger.warn("terminal", "Invalid custom table provider: " .. error_msg .. ". Falling back to 'native'.")
    end
    -- Fall through to native provider
  elseif defaults.provider == "auto" then
    -- Try snacks first, then fallback to native silently
    local snacks_provider = load_provider("snacks")
    if snacks_provider and snacks_provider.is_available() then
      return snacks_provider
    end
    -- Fall through to native provider
  elseif defaults.provider == "snacks" then
    local snacks_provider = load_provider("snacks")
    if snacks_provider and snacks_provider.is_available() then
      return snacks_provider
    else
      logger.warn("terminal", "'snacks' provider configured, but Snacks.nvim not available. Falling back to 'native'.")
    end
  elseif defaults.provider == "external" then
    local external_provider = load_provider("external")
    if external_provider then
      -- Check availability based on our config instead of provider's internal state
      local external_cmd = defaults.provider_opts and defaults.provider_opts.external_terminal_cmd

      local has_external_cmd = false
      if type(external_cmd) == "function" then
        has_external_cmd = true
      elseif type(external_cmd) == "string" and external_cmd ~= "" and external_cmd:find("%%s") then
        has_external_cmd = true
      end

      if has_external_cmd then
        return external_provider
      else
        logger.warn(
          "terminal",
          "'external' provider configured, but provider_opts.external_terminal_cmd not properly set. Falling back to 'native'."
        )
      end
    end
  elseif defaults.provider == "native" then
    -- noop, will use native provider as default below
    logger.debug("terminal", "Using native terminal provider")
  elseif defaults.provider == "none" then
    local none_provider = load_provider("none")
    if none_provider then
      logger.debug("terminal", "Using no-op terminal provider ('none')")
      return none_provider
    else
      logger.warn("terminal", "'none' provider configured but failed to load. Falling back to 'native'.")
    end
  elseif type(defaults.provider) == "string" then
    logger.warn(
      "terminal",
      "Invalid provider configured: " .. tostring(defaults.provider) .. ". Defaulting to 'native'."
    )
  else
    logger.warn(
      "terminal",
      "Invalid provider type: " .. type(defaults.provider) .. ". Must be string or table. Defaulting to 'native'."
    )
  end

  local native_provider = load_provider("native")
  if not native_provider then
    error("ClaudeCode: Critical error - native terminal provider failed to load")
  end
  return native_provider
end

---Builds the effective terminal configuration by merging defaults with overrides
---@param opts_override table? Optional overrides for terminal appearance
---@return table config The effective terminal configuration
local function build_config(opts_override)
  local effective_config = vim.deepcopy(defaults)
  if type(opts_override) == "table" then
    local validators = {
      split_side = function(val)
        return val == "left" or val == "right"
      end,
      split_width_percentage = function(val)
        return type(val) == "number" and val > 0 and val < 1
      end,
      snacks_win_opts = function(val)
        return type(val) == "table"
      end,
      cwd = function(val)
        return val == nil or type(val) == "string"
      end,
      git_repo_cwd = function(val)
        return type(val) == "boolean"
      end,
      cwd_provider = function(val)
        local t = type(val)
        if t == "function" then
          return true
        end
        if t == "table" then
          local mt = getmetatable(val)
          return mt and mt.__call ~= nil
        end
        return false
      end,
    }
    for key, val in pairs(opts_override) do
      if effective_config[key] ~= nil and validators[key] and validators[key](val) then
        effective_config[key] = val
      end
    end
  end
  -- Resolve cwd at config-build time so providers receive it directly
  local cwd_ctx = {
    file = (function()
      local path = vim.fn.expand("%:p")
      if type(path) == "string" and path ~= "" then
        return path
      end
      return nil
    end)(),
    cwd = vim.fn.getcwd(),
  }
  cwd_ctx.file_dir = cwd_ctx.file and vim.fn.fnamemodify(cwd_ctx.file, ":h") or nil

  local resolved_cwd = nil
  -- Prefer provider function, then static cwd, then git root via resolver
  if effective_config.cwd_provider then
    local ok_p, res = pcall(effective_config.cwd_provider, cwd_ctx)
    if ok_p and type(res) == "string" and res ~= "" then
      resolved_cwd = vim.fn.expand(res)
    end
  end
  if not resolved_cwd and type(effective_config.cwd) == "string" and effective_config.cwd ~= "" then
    resolved_cwd = vim.fn.expand(effective_config.cwd)
  end
  if not resolved_cwd and effective_config.git_repo_cwd then
    local ok_r, cwd_mod = pcall(require, "claudecode.cwd")
    if ok_r and cwd_mod and type(cwd_mod.git_root) == "function" then
      resolved_cwd = cwd_mod.git_root(cwd_ctx.file_dir or cwd_ctx.cwd)
    end
  end

  return {
    split_side = effective_config.split_side,
    split_width_percentage = effective_config.split_width_percentage,
    auto_close = effective_config.auto_close,
    snacks_win_opts = effective_config.snacks_win_opts,
    cwd = resolved_cwd,
  }
end

---Checks if a terminal buffer is currently visible in any window
---@param bufnr number? The buffer number to check
---@return boolean True if the buffer is visible in any window, false otherwise
local function is_terminal_visible(bufnr)
  if not bufnr then
    return false
  end

  local bufinfo = vim.fn.getbufinfo(bufnr)
  return bufinfo and #bufinfo > 0 and #bufinfo[1].windows > 0
end

---Gets the claude command string and necessary environment variables
---@param cmd_args string? Optional arguments to append to the command
---@return string cmd_string The command string
---@return table env_table The environment variables table
local function get_claude_command_and_env(cmd_args)
  -- Inline get_claude_command logic
  local cmd_from_config = defaults.terminal_cmd
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

  -- Merge custom environment variables from config
  for key, value in pairs(defaults.env) do
    env_table[key] = value
  end

  return cmd_string, env_table
end

---Common helper to open terminal without focus if not already visible
---@param opts_override table? Optional config overrides
---@param cmd_args string? Optional command arguments
---@return boolean visible True if terminal was opened or already visible
local function ensure_terminal_visible_no_focus(opts_override, cmd_args)
  local provider = get_provider()

  -- Check if provider has an ensure_visible method
  if provider.ensure_visible then
    provider.ensure_visible()
    return true
  end

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

---Configures the terminal module.
---Merges user-provided terminal configuration with defaults and sets the terminal command.
---@param user_term_config ClaudeCodeTerminalConfig? Configuration options for the terminal.
---@param p_terminal_cmd string? The command to run in the terminal (from main config).
---@param p_env table? Custom environment variables to pass to the terminal (from main config).
function M.setup(user_term_config, p_terminal_cmd, p_env)
  if user_term_config == nil then -- Allow nil, default to empty table silently
    user_term_config = {}
  elseif type(user_term_config) ~= "table" then -- Warn if it's not nil AND not a table
    vim.notify("claudecode.terminal.setup expects a table or nil for user_term_config", vim.log.levels.WARN)
    user_term_config = {}
  end

  if p_terminal_cmd == nil or type(p_terminal_cmd) == "string" then
    defaults.terminal_cmd = p_terminal_cmd
  else
    vim.notify(
      "claudecode.terminal.setup: Invalid terminal_cmd provided: " .. tostring(p_terminal_cmd) .. ". Using default.",
      vim.log.levels.WARN
    )
    defaults.terminal_cmd = nil -- Fallback to default behavior
  end

  if p_env == nil or type(p_env) == "table" then
    defaults.env = p_env or {}
  else
    vim.notify(
      "claudecode.terminal.setup: Invalid env provided: " .. tostring(p_env) .. ". Using empty table.",
      vim.log.levels.WARN
    )
    defaults.env = {}
  end

  for k, v in pairs(user_term_config) do
    if k == "split_side" then
      if v == "left" or v == "right" then
        defaults.split_side = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for split_side: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "split_width_percentage" then
      if type(v) == "number" and v > 0 and v < 1 then
        defaults.split_width_percentage = v
      else
        vim.notify(
          "claudecode.terminal.setup: Invalid value for split_width_percentage: " .. tostring(v),
          vim.log.levels.WARN
        )
      end
    elseif k == "provider" then
      if type(v) == "table" or v == "snacks" or v == "native" or v == "external" or v == "auto" or v == "none" then
        defaults.provider = v
      else
        vim.notify(
          "claudecode.terminal.setup: Invalid value for provider: " .. tostring(v) .. ". Defaulting to 'native'.",
          vim.log.levels.WARN
        )
      end
    elseif k == "provider_opts" then
      -- Handle nested provider options
      if type(v) == "table" then
        defaults[k] = defaults[k] or {}
        for opt_k, opt_v in pairs(v) do
          if opt_k == "external_terminal_cmd" then
            if opt_v == nil or type(opt_v) == "string" or type(opt_v) == "function" then
              defaults[k][opt_k] = opt_v
            else
              vim.notify(
                "claudecode.terminal.setup: Invalid value for provider_opts.external_terminal_cmd: " .. tostring(opt_v),
                vim.log.levels.WARN
              )
            end
          else
            -- For other provider options, just copy them
            defaults[k][opt_k] = opt_v
          end
        end
      else
        vim.notify("claudecode.terminal.setup: Invalid value for provider_opts: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "show_native_term_exit_tip" then
      if type(v) == "boolean" then
        defaults.show_native_term_exit_tip = v
      else
        vim.notify(
          "claudecode.terminal.setup: Invalid value for show_native_term_exit_tip: " .. tostring(v),
          vim.log.levels.WARN
        )
      end
    elseif k == "auto_close" then
      if type(v) == "boolean" then
        defaults.auto_close = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for auto_close: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "snacks_win_opts" then
      if type(v) == "table" then
        defaults.snacks_win_opts = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for snacks_win_opts", vim.log.levels.WARN)
      end
    elseif k == "cwd" then
      if v == nil or type(v) == "string" then
        defaults.cwd = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for cwd: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "git_repo_cwd" then
      if type(v) == "boolean" then
        defaults.git_repo_cwd = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for git_repo_cwd: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "cwd_provider" then
      local t = type(v)
      if t == "function" then
        defaults.cwd_provider = v
      elseif t == "table" then
        local mt = getmetatable(v)
        if mt and mt.__call then
          defaults.cwd_provider = v
        else
          vim.notify(
            "claudecode.terminal.setup: cwd_provider table is not callable (missing __call)",
            vim.log.levels.WARN
          )
        end
      else
        vim.notify("claudecode.terminal.setup: Invalid cwd_provider type: " .. tostring(t), vim.log.levels.WARN)
      end
    else
      if k ~= "terminal_cmd" then
        vim.notify("claudecode.terminal.setup: Unknown configuration key: " .. k, vim.log.levels.WARN)
      end
    end
  end

  -- Setup providers with config
  get_provider().setup(defaults)
end

---Opens or focuses the Claude terminal.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.open(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  get_provider().open(cmd_string, claude_env_table, effective_config)
end

---Closes the managed Claude terminal if it's open and valid.
function M.close()
  get_provider().close()
end

---Simple toggle: always show/hide the Claude terminal regardless of focus.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.simple_toggle(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  get_provider().simple_toggle(cmd_string, claude_env_table, effective_config)
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused.
---@param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string|nil (optional) Arguments to append to the claude command.
function M.focus_toggle(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  get_provider().focus_toggle(cmd_string, claude_env_table, effective_config)
end

---Toggle open terminal without focus if not already visible, otherwise do nothing.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.toggle_open_no_focus(opts_override, cmd_args)
  ensure_terminal_visible_no_focus(opts_override, cmd_args)
end

---Ensures terminal is visible without changing focus. Creates if necessary, shows if hidden.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.ensure_visible(opts_override, cmd_args)
  ensure_terminal_visible_no_focus(opts_override, cmd_args)
end

---Toggles the Claude terminal open or closed (legacy function - use simple_toggle or focus_toggle).
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.toggle(opts_override, cmd_args)
  -- Default to simple toggle for backward compatibility
  M.simple_toggle(opts_override, cmd_args)
end

---Gets the buffer number of the currently active Claude Code terminal.
---This checks both Snacks and native fallback terminals.
---@return number|nil The buffer number if an active terminal is found, otherwise nil.
function M.get_active_terminal_bufnr()
  return get_provider().get_active_bufnr()
end

---Gets the managed terminal instance for testing purposes.
-- NOTE: This function is intended for use in tests to inspect internal state.
-- The underscore prefix indicates it's not part of the public API for regular use.
---@return table|nil terminal The managed terminal instance, or nil.
function M._get_managed_terminal_for_test()
  local provider = get_provider()
  if provider and provider._get_terminal_for_test then
    return provider._get_terminal_for_test()
  end
  return nil
end

return M
