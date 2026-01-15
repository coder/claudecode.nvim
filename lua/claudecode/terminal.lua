--- Module to manage dedicated vertical split terminals for Claude Code.
--- Supports Snacks.nvim or a native Neovim terminal fallback.
--- Now supports multiple concurrent terminal sessions.
--- @module 'claudecode.terminal'

local M = {}

local claudecode_server_module = require("claudecode.server.init")
local osc_handler = require("claudecode.terminal.osc_handler")
local session_manager = require("claudecode.session")

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
  -- Terminal keymaps
  keymaps = {
    exit_terminal = "<Esc><Esc>", -- Double-ESC to exit terminal mode (set to false to disable)
  },
  -- Smart ESC handling: timeout in ms to wait for second ESC before sending ESC to terminal
  -- Set to nil or 0 to disable smart ESC handling (use simple keymap instead)
  esc_timeout = 200,
  -- Tab bar for session switching (optional)
  tabs = {
    enabled = false, -- Off by default
    height = 1, -- Height of tab bar in lines
    show_close_button = true, -- Show [x] close button on tabs
    show_new_button = true, -- Show [+] button for new session
    separator = " | ", -- Separator between tabs
    active_indicator = "*", -- Indicator for active tab
    mouse_enabled = false, -- Mouse clicks optional, off by default
    keymaps = {
      next_tab = "<A-Tab>", -- Switch to next session (Alt+Tab)
      prev_tab = "<A-S-Tab>", -- Switch to previous session (Alt+Shift+Tab)
      close_tab = "<A-w>", -- Close current tab (Alt+w)
      new_tab = "<A-+>", -- Create new session (Alt++)
    },
  },
}

M.defaults = defaults

-- ============================================================================
-- Smart ESC handler for terminal mode
-- ============================================================================

-- State for tracking ESC key presses per buffer
local esc_state = {}

---Creates a smart ESC handler for a terminal buffer.
---This handler intercepts ESC presses and waits for a second ESC within the timeout.
---If a second ESC arrives, it exits terminal mode. Otherwise, sends ESC to the terminal.
---@param bufnr number The terminal buffer number
---@param timeout_ms number Timeout in milliseconds to wait for second ESC
---@return function handler The ESC key handler function
function M.create_smart_esc_handler(bufnr, timeout_ms)
  return function()
    local state = esc_state[bufnr]

    if state and state.waiting then
      -- Second ESC within timeout - exit terminal mode
      state.waiting = false
      if state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
      end
      -- Exit terminal mode
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "n", false)
    else
      -- First ESC - start waiting for second ESC
      esc_state[bufnr] = { waiting = true, timer = nil }
      state = esc_state[bufnr]

      state.timer = vim.uv.new_timer()
      state.timer:start(
        timeout_ms,
        0,
        vim.schedule_wrap(function()
          -- Timeout expired - send ESC to the terminal
          if esc_state[bufnr] and esc_state[bufnr].waiting then
            esc_state[bufnr].waiting = false
            if esc_state[bufnr].timer then
              esc_state[bufnr].timer:stop()
              esc_state[bufnr].timer:close()
              esc_state[bufnr].timer = nil
            end
            -- Send ESC directly to the terminal channel, bypassing keymaps
            -- Get the terminal channel from the buffer
            if vim.api.nvim_buf_is_valid(bufnr) then
              local channel = vim.bo[bufnr].channel
              if channel and channel > 0 then
                -- Send raw ESC byte (0x1b = 27) directly to terminal
                vim.fn.chansend(channel, "\027")
              end
            end
          end
        end)
      )
    end
  end
end

---Sets up smart ESC handling for a terminal buffer.
---If smart ESC is enabled (esc_timeout > 0), maps single ESC to smart handler.
---Otherwise falls back to simple double-ESC mapping.
---@param bufnr number The terminal buffer number
---@param config table The terminal configuration (with keymaps and esc_timeout)
function M.setup_terminal_keymaps(bufnr, config)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local timeout = config.esc_timeout
  local exit_key = config.keymaps and config.keymaps.exit_terminal

  if exit_key == false then
    -- ESC handling disabled
    return
  end

  if timeout and timeout > 0 then
    -- Smart ESC handling: intercept single ESC
    local handler = M.create_smart_esc_handler(bufnr, timeout)
    vim.keymap.set("t", "<Esc>", handler, {
      buffer = bufnr,
      desc = "Smart ESC: double-tap to exit terminal mode, single to send ESC",
    })
  elseif exit_key then
    -- Fallback: simple keymap (legacy behavior)
    vim.keymap.set("t", exit_key, "<C-\\><C-n>", {
      buffer = bufnr,
      desc = "Exit terminal mode",
    })
  end
end

---Cleanup ESC state for a buffer (call when buffer is deleted)
---@param bufnr number The terminal buffer number
function M.cleanup_esc_state(bufnr)
  local state = esc_state[bufnr]
  if state then
    if state.timer then
      state.timer:stop()
      state.timer:close()
    end
    esc_state[bufnr] = nil
  end
end

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
    keymaps = effective_config.keymaps,
    esc_timeout = effective_config.esc_timeout,
  }
end

---Checks if a terminal buffer is currently visible in any window
---@param bufnr number? The buffer number to check
---@return boolean True if the buffer is visible in any window, false otherwise
local function is_terminal_visible(bufnr)
  if not bufnr then
    return false
  end

  -- Protect against missing vim.fn.getbufinfo in test environment
  if not vim.fn or not vim.fn.getbufinfo then
    return false
  end

  local ok, bufinfo = pcall(vim.fn.getbufinfo, bufnr)
  if not ok then
    return false
  end
  return bufinfo and #bufinfo > 0 and #bufinfo[1].windows > 0
end

---Attach the tab bar to a terminal window if tabs are enabled
---@param terminal_winid number The terminal window ID
---@param terminal_bufnr number|nil The terminal buffer number (for keymaps)
local function attach_tabbar(terminal_winid, terminal_bufnr)
  if not defaults.tabs or not defaults.tabs.enabled then
    return
  end

  if not terminal_winid or not vim.api.nvim_win_is_valid(terminal_winid) then
    return
  end

  local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
  if ok then
    tabbar.attach(terminal_winid, terminal_bufnr)
  end
end

---Detach the tab bar from the terminal
local function detach_tabbar()
  if not defaults.tabs or not defaults.tabs.enabled then
    return
  end

  local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
  if ok then
    tabbar.detach()
  end
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
  local had_terminal = active_bufnr ~= nil

  if is_terminal_visible(active_bufnr) then
    -- Terminal is already visible, do nothing
    return true
  end

  -- Terminal is not visible, open it without focus
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  provider.open(cmd_string, claude_env_table, effective_config, false) -- false = don't focus

  -- If we didn't have a terminal before but do now, ensure a session exists
  if not had_terminal then
    local new_bufnr = provider.get_active_bufnr()
    if new_bufnr then
      -- Ensure we have a session for this terminal
      local session_id = session_manager.ensure_session()
      -- Update session with terminal info
      session_manager.update_terminal_info(session_id, {
        bufnr = new_bufnr,
      })
      -- Register terminal with provider for session switching support
      if provider.register_terminal_for_session then
        provider.register_terminal_for_session(session_id, new_bufnr)
      end
    end
  end

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
    elseif k == "keymaps" then
      if type(v) == "table" then
        defaults.keymaps = defaults.keymaps or {}
        for keymap_k, keymap_v in pairs(v) do
          if keymap_k == "exit_terminal" then
            if keymap_v == false or type(keymap_v) == "string" then
              defaults.keymaps.exit_terminal = keymap_v
            else
              vim.notify(
                "claudecode.terminal.setup: Invalid value for keymaps.exit_terminal: "
                  .. tostring(keymap_v)
                  .. ". Must be a string or false.",
                vim.log.levels.WARN
              )
            end
          else
            vim.notify("claudecode.terminal.setup: Unknown keymap key: " .. tostring(keymap_k), vim.log.levels.WARN)
          end
        end
      else
        vim.notify(
          "claudecode.terminal.setup: Invalid value for keymaps: " .. tostring(v) .. ". Must be a table.",
          vim.log.levels.WARN
        )
      end
    elseif k == "esc_timeout" then
      if v == nil or (type(v) == "number" and v >= 0) then
        defaults.esc_timeout = v
      else
        vim.notify(
          "claudecode.terminal.setup: Invalid value for esc_timeout: "
            .. tostring(v)
            .. ". Must be a number >= 0 or nil.",
          vim.log.levels.WARN
        )
      end
    elseif k == "tabs" then
      if type(v) == "table" then
        defaults.tabs = defaults.tabs or {}
        for tabs_k, tabs_v in pairs(v) do
          if tabs_k == "enabled" then
            if type(tabs_v) == "boolean" then
              defaults.tabs.enabled = tabs_v
            else
              vim.notify(
                "claudecode.terminal.setup: Invalid value for tabs.enabled: " .. tostring(tabs_v),
                vim.log.levels.WARN
              )
            end
          elseif tabs_k == "height" then
            if type(tabs_v) == "number" and tabs_v >= 1 then
              defaults.tabs.height = tabs_v
            else
              vim.notify(
                "claudecode.terminal.setup: Invalid value for tabs.height: " .. tostring(tabs_v),
                vim.log.levels.WARN
              )
            end
          elseif tabs_k == "show_close_button" then
            if type(tabs_v) == "boolean" then
              defaults.tabs.show_close_button = tabs_v
            end
          elseif tabs_k == "show_new_button" then
            if type(tabs_v) == "boolean" then
              defaults.tabs.show_new_button = tabs_v
            end
          elseif tabs_k == "separator" then
            if type(tabs_v) == "string" then
              defaults.tabs.separator = tabs_v
            end
          elseif tabs_k == "active_indicator" then
            if type(tabs_v) == "string" then
              defaults.tabs.active_indicator = tabs_v
            end
          elseif tabs_k == "mouse_enabled" then
            if type(tabs_v) == "boolean" then
              defaults.tabs.mouse_enabled = tabs_v
            end
          elseif tabs_k == "keymaps" then
            if type(tabs_v) == "table" then
              defaults.tabs.keymaps = defaults.tabs.keymaps or {}
              for km_k, km_v in pairs(tabs_v) do
                if km_v == false or type(km_v) == "string" then
                  defaults.tabs.keymaps[km_k] = km_v
                end
              end
            end
          end
        end
      else
        vim.notify(
          "claudecode.terminal.setup: Invalid value for tabs: " .. tostring(v) .. ". Must be a table.",
          vim.log.levels.WARN
        )
      end
    else
      if k ~= "terminal_cmd" then
        vim.notify("claudecode.terminal.setup: Unknown configuration key: " .. k, vim.log.levels.WARN)
      end
    end
  end

  -- Setup window manager with config
  local window_manager = require("claudecode.terminal.window_manager")
  window_manager.setup({
    split_side = defaults.split_side,
    split_width_percentage = defaults.split_width_percentage,
  })

  -- Setup providers with config
  get_provider().setup(defaults)

  -- Setup tab bar if configured
  if defaults.tabs then
    local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
    if ok then
      tabbar.setup(defaults.tabs)
    end
  end
end

---Opens or focuses the Claude terminal.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.open(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  local provider = get_provider()
  local had_terminal = provider.get_active_bufnr() ~= nil

  provider.open(cmd_string, claude_env_table, effective_config)

  -- If we didn't have a terminal before but do now, ensure a session exists
  if not had_terminal then
    local active_bufnr = provider.get_active_bufnr()
    if active_bufnr then
      -- Ensure we have a session for this terminal
      local session_id = session_manager.ensure_session()
      -- Update session with terminal info
      session_manager.update_terminal_info(session_id, {
        bufnr = active_bufnr,
      })
      -- Register terminal with provider for session switching support
      if provider.register_terminal_for_session then
        provider.register_terminal_for_session(session_id, active_bufnr)
      end
    end
  end

  -- Attach tab bar if enabled (find terminal window from buffer)
  local active_bufnr = provider.get_active_bufnr()
  if active_bufnr and vim.fn.getbufinfo then
    local ok, bufinfo = pcall(vim.fn.getbufinfo, active_bufnr)
    if ok and bufinfo and #bufinfo > 0 and #bufinfo[1].windows > 0 then
      attach_tabbar(bufinfo[1].windows[1], active_bufnr)
    end
  end
end

---Closes the managed Claude terminal if it's open and valid.
function M.close()
  detach_tabbar()
  -- Call provider's close for backwards compatibility
  get_provider().close()
end

---Simple toggle: always show/hide the Claude terminal regardless of focus.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.simple_toggle(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  -- Check if we had a terminal before the toggle
  local provider = get_provider()
  local had_terminal = provider.get_active_bufnr() ~= nil
  local was_visible = is_terminal_visible(provider.get_active_bufnr())

  provider.simple_toggle(cmd_string, claude_env_table, effective_config)

  -- If we didn't have a terminal before but do now, ensure a session exists
  if not had_terminal then
    local active_bufnr = provider.get_active_bufnr()
    if active_bufnr then
      -- Ensure we have a session for this terminal
      local session_id = session_manager.ensure_session()
      -- Update session with terminal info
      session_manager.update_terminal_info(session_id, {
        bufnr = active_bufnr,
      })
      -- Register terminal with provider for session switching support
      if provider.register_terminal_for_session then
        provider.register_terminal_for_session(session_id, active_bufnr)
      end
      -- Setup title watcher to capture terminal title changes
      osc_handler.setup_buffer_handler(active_bufnr, function(title)
        if title and title ~= "" then
          session_manager.update_session_name(session_id, title)
        end
      end)
    end
  end

  -- Handle tab bar visibility based on terminal visibility
  local active_bufnr = provider.get_active_bufnr()
  local is_visible_now = is_terminal_visible(active_bufnr)

  if is_visible_now and not was_visible then
    -- Terminal just became visible, attach tab bar
    if active_bufnr and vim.fn.getbufinfo then
      local ok, bufinfo = pcall(vim.fn.getbufinfo, active_bufnr)
      if ok and bufinfo and #bufinfo > 0 and #bufinfo[1].windows > 0 then
        attach_tabbar(bufinfo[1].windows[1], active_bufnr)
      end
    end
  elseif was_visible and not is_visible_now then
    -- Terminal was hidden, detach tab bar
    detach_tabbar()
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused.
---@param opts_override table (optional) Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string|nil (optional) Arguments to append to the claude command.
function M.focus_toggle(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  -- Check if we had a terminal before the toggle
  local provider = get_provider()
  local had_terminal = provider.get_active_bufnr() ~= nil
  local was_visible = is_terminal_visible(provider.get_active_bufnr())

  provider.focus_toggle(cmd_string, claude_env_table, effective_config)

  -- If we didn't have a terminal before but do now, ensure a session exists
  if not had_terminal then
    local active_bufnr = provider.get_active_bufnr()
    if active_bufnr then
      -- Ensure we have a session for this terminal
      local session_id = session_manager.ensure_session()
      -- Update session with terminal info
      session_manager.update_terminal_info(session_id, {
        bufnr = active_bufnr,
      })
      -- Register terminal with provider for session switching support
      if provider.register_terminal_for_session then
        provider.register_terminal_for_session(session_id, active_bufnr)
      end
      -- Setup OSC title handler to capture terminal title changes
      osc_handler.setup_buffer_handler(active_bufnr, function(title)
        if title and title ~= "" then
          session_manager.update_session_name(session_id, title)
        end
      end)
    end
  end

  -- Handle tab bar visibility based on terminal visibility
  local active_bufnr = provider.get_active_bufnr()
  local is_visible_now = is_terminal_visible(active_bufnr)

  if is_visible_now and not was_visible then
    -- Terminal just became visible, attach tab bar
    if active_bufnr and vim.fn.getbufinfo then
      local ok, bufinfo = pcall(vim.fn.getbufinfo, active_bufnr)
      if ok and bufinfo and #bufinfo > 0 and #bufinfo[1].windows > 0 then
        attach_tabbar(bufinfo[1].windows[1], active_bufnr)
      end
    end
  elseif was_visible and not is_visible_now then
    -- Terminal was hidden, detach tab bar
    detach_tabbar()
  end
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

-- ============================================================================
-- Multi-session support functions
-- ============================================================================

---Opens a new Claude terminal session.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
---@return string session_id The ID of the new session
function M.open_new_session(opts_override, cmd_args)
  local session_id = session_manager.create_session()
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  -- Make the new session active immediately
  session_manager.set_active_session(session_id)

  local provider = get_provider()

  -- For multi-session, we need to pass session_id to providers
  if provider.open_session then
    provider.open_session(session_id, cmd_string, claude_env_table, effective_config, true) -- true = focus
  else
    -- Fallback: use regular open (single terminal mode)
    provider.open(cmd_string, claude_env_table, effective_config, true) -- true = focus
  end

  return session_id
end

---Closes a specific session.
---@param session_id string? The session ID to close (defaults to active session)
function M.close_session(session_id)
  session_id = session_id or session_manager.get_active_session_id()
  if not session_id then
    return
  end

  local provider = get_provider()
  local effective_config = build_config(nil)

  -- Check if there are other sessions to switch to
  local session_count = session_manager.get_session_count()

  if session_count > 1 then
    -- There are other sessions - keep the window and switch to another session
    -- Figure out which session to switch to: prefer previous tab, fallback to next
    local sessions = session_manager.list_sessions()
    local new_active_id = nil
    local current_index = nil

    -- Find the index of the session being closed
    for i, s in ipairs(sessions) do
      if s.id == session_id then
        current_index = i
        break
      end
    end

    if current_index then
      -- Prefer previous tab (index - 1), fallback to next tab (index + 1)
      if current_index > 1 then
        new_active_id = sessions[current_index - 1].id
      elseif current_index < #sessions then
        new_active_id = sessions[current_index + 1].id
      end
    end

    -- Fallback: just pick any other session
    if not new_active_id then
      for _, s in ipairs(sessions) do
        if s.id ~= session_id then
          new_active_id = s.id
          break
        end
      end
    end

    if new_active_id and provider.close_session_keep_window then
      -- Use close_session_keep_window to keep window open and switch buffer
      -- This function handles cleanup of the old session internally
      provider.close_session_keep_window(session_id, new_active_id, effective_config)
      session_manager.destroy_session(session_id)
      session_manager.set_active_session(new_active_id)
    else
      -- Fallback: close and reopen
      session_manager.destroy_session(session_id)
      new_active_id = session_manager.get_active_session_id()

      if provider.close_session then
        provider.close_session(session_id)
      else
        provider.close()
      end

      if new_active_id and provider.focus_session then
        provider.focus_session(new_active_id, effective_config)
      end
    end

    -- Re-attach tabbar to the new session's terminal
    if new_active_id then
      local new_bufnr
      if provider.get_session_bufnr then
        new_bufnr = provider.get_session_bufnr(new_active_id)
      else
        new_bufnr = provider.get_active_bufnr()
      end

      if new_bufnr and vim.fn.getbufinfo then
        local ok, bufinfo = pcall(vim.fn.getbufinfo, new_bufnr)
        if ok and bufinfo and #bufinfo > 0 and #bufinfo[1].windows > 0 then
          attach_tabbar(bufinfo[1].windows[1], new_bufnr)
        end
      end
    end
  else
    -- This is the last session - close everything
    detach_tabbar()

    if provider.close_session then
      provider.close_session(session_id)
    else
      provider.close()
    end

    session_manager.destroy_session(session_id)
  end
end

---Switches to a specific session.
---@param session_id string The session ID to switch to
---@param opts_override table? Optional config overrides
function M.switch_to_session(session_id, opts_override)
  local session = session_manager.get_session(session_id)
  if not session then
    local logger = require("claudecode.logger")
    logger.warn("terminal", "Cannot switch to non-existent session: " .. session_id)
    return
  end

  session_manager.set_active_session(session_id)

  local provider = get_provider()

  if provider.focus_session then
    local effective_config = build_config(opts_override)
    provider.focus_session(session_id, effective_config)
  elseif session.terminal_bufnr and vim.api.nvim_buf_is_valid(session.terminal_bufnr) then
    -- Fallback: try to find and focus the window
    local windows = vim.api.nvim_list_wins()
    for _, win in ipairs(windows) do
      if vim.api.nvim_win_get_buf(win) == session.terminal_bufnr then
        vim.api.nvim_set_current_win(win)
        vim.cmd("startinsert")
        return
      end
    end
  end
end

---Gets the session ID for the currently focused terminal.
---@return string|nil session_id The session ID or nil if not in a session terminal
function M.get_current_session_id()
  local current_buf = vim.api.nvim_get_current_buf()
  local session = session_manager.find_session_by_bufnr(current_buf)
  if session then
    return session.id
  end
  return nil
end

---Lists all active sessions.
---@return table[] sessions Array of session info
function M.list_sessions()
  return session_manager.list_sessions()
end

---Gets the number of active sessions.
---@return number count Number of active sessions
function M.get_session_count()
  return session_manager.get_session_count()
end

---Updates terminal info for a session (called by providers).
---@param session_id string The session ID
---@param terminal_info table { bufnr?: number, winid?: number, jobid?: number }
function M.update_session_terminal_info(session_id, terminal_info)
  session_manager.update_terminal_info(session_id, terminal_info)
end

---Gets the active session ID.
---@return string|nil session_id The active session ID
function M.get_active_session_id()
  return session_manager.get_active_session_id()
end

---Ensures at least one session exists and returns its ID.
---@return string session_id The session ID
function M.ensure_session()
  return session_manager.ensure_session()
end

return M
