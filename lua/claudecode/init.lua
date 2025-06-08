---@brief [[
--- Claude Code Neovim Integration
--- This plugin integrates Claude Code CLI with Neovim, enabling
--- seamless AI-assisted coding experiences directly in Neovim.
---@brief ]]

--- @module 'claudecode'
local M = {}

--- @class ClaudeCode.Version
--- @field major integer Major version number
--- @field minor integer Minor version number
--- @field patch integer Patch version number
--- @field prerelease string|nil Prerelease identifier (e.g., "alpha", "beta")
--- @field string fun(self: ClaudeCode.Version):string Returns the formatted version string

--- The current version of the plugin.
--- @type ClaudeCode.Version
M.version = {
  major = 0,
  minor = 1,
  patch = 0,
  prerelease = "alpha",
  string = function(self)
    local version = string.format("%d.%d.%d", self.major, self.minor, self.patch)
    if self.prerelease then
      version = version .. "-" .. self.prerelease
    end
    return version
  end,
}

--- @class ClaudeCode.Config
--- @field port_range {min: integer, max: integer} Port range for WebSocket server.
--- @field auto_start boolean Auto-start WebSocket server on Neovim startup.
--- @field terminal_cmd string|nil Custom terminal command to use when launching Claude.
--- @field log_level "trace"|"debug"|"info"|"warn"|"error" Log level.
--- @field track_selection boolean Enable sending selection updates to Claude.
--- @field visual_demotion_delay_ms number Milliseconds to wait before demoting a visual selection.
--- @field diff_opts { auto_close_on_accept: boolean, show_diff_stats: boolean, vertical_split: boolean, open_in_current_tab: boolean } Options for the diff provider.

--- @type ClaudeCode.Config
local default_config = {
  port_range = { min = 10000, max = 65535 },
  auto_start = true,
  terminal_cmd = nil,
  log_level = "info",
  track_selection = true,
  visual_demotion_delay_ms = 200,
  diff_opts = {
    auto_close_on_accept = true,
    show_diff_stats = true,
    vertical_split = true,
    open_in_current_tab = false,
  },
}

--- @class ClaudeCode.State
--- @field config ClaudeCode.Config The current plugin configuration.
--- @field server table|nil The WebSocket server instance.
--- @field port number|nil The port the server is running on.
--- @field initialized boolean Whether the plugin has been initialized.

--- @type ClaudeCode.State
M.state = {
  config = vim.deepcopy(default_config),
  server = nil,
  port = nil,
  initialized = false,
}

---@alias ClaudeCode.TerminalOpts { \
---  split_side?: "left"|"right", \
---  split_width_percentage?: number, \
---  provider?: "snacks"|"native", \
---  show_native_term_exit_tip?: boolean }
---
---@alias ClaudeCode.SetupOpts { \
---  terminal?: ClaudeCode.TerminalOpts }
---
--- Set up the plugin with user configuration
---@param opts ClaudeCode.SetupOpts|nil Optional configuration table to override defaults.
---@return table The plugin module
function M.setup(opts)
  opts = opts or {}

  local terminal_opts = nil
  if opts.terminal then
    terminal_opts = opts.terminal
    opts.terminal = nil -- Remove from main opts to avoid polluting M.state.config
  end

  local config = require("claudecode.config")
  M.state.config = config.apply(opts)
  -- vim.g.claudecode_user_config is no longer needed as config values are passed directly.

  local logger = require("claudecode.logger")
  logger.setup(M.state.config)

  -- Setup terminal module: always try to call setup to pass terminal_cmd,
  -- even if terminal_opts (for split_side etc.) are not provided.
  local terminal_setup_ok, terminal_module = pcall(require, "claudecode.terminal")
  if terminal_setup_ok then
    -- terminal_opts might be nil if user only configured top-level terminal_cmd
    -- and not specific terminal appearance options.
    -- The terminal.setup function handles nil for its first argument.
    terminal_module.setup(terminal_opts, M.state.config.terminal_cmd)
  else
    logger.error("init", "Failed to load claudecode.terminal module for setup.")
  end

  local diff = require("claudecode.diff")
  diff.setup(M.state.config)

  if M.state.config.auto_start then
    M.start(false) -- Suppress notification on auto-start
  end

  M._create_commands()

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ClaudeCodeShutdown", { clear = true }),
    callback = function()
      if M.state.server then
        M.stop()
      end
    end,
    desc = "Automatically stop Claude Code integration when exiting Neovim",
  })

  M.state.initialized = true
  return M
end

--- Start the Claude Code integration
---@param show_startup_notification? boolean Whether to show a notification upon successful startup (defaults to true)
---@return boolean success Whether the operation was successful
---@return number|string port_or_error The WebSocket port if successful, or error message if failed
function M.start(show_startup_notification)
  if show_startup_notification == nil then
    show_startup_notification = true
  end
  if M.state.server then
    local msg = "Claude Code integration is already running on port " .. tostring(M.state.port)
    vim.notify(msg, vim.log.levels.WARN)
    return false, "Already running"
  end

  local server = require("claudecode.server.init")
  local success, result = server.start(M.state.config)

  if not success then
    vim.notify("Failed to start Claude Code integration: " .. result, vim.log.levels.ERROR)
    return false, result
  end

  M.state.server = server
  M.state.port = tonumber(result)

  local lockfile = require("claudecode.lockfile")
  local lock_success, lock_result = lockfile.create(M.state.port)

  if not lock_success then
    server.stop()
    M.state.server = nil
    M.state.port = nil

    vim.notify("Failed to create lock file: " .. lock_result, vim.log.levels.ERROR)
    return false, lock_result
  end

  if M.state.config.track_selection then
    local selection = require("claudecode.selection")
    selection.enable(M.state.server, M.state.config.visual_demotion_delay_ms)
  end

  if show_startup_notification then
    vim.notify("Claude Code integration started on port " .. tostring(M.state.port), vim.log.levels.INFO)
  end

  return true, M.state.port
end

--- Stop the Claude Code integration
---@return boolean success Whether the operation was successful
---@return string? error Error message if operation failed
function M.stop()
  if not M.state.server then
    vim.notify("Claude Code integration is not running", vim.log.levels.WARN)
    return false, "Not running"
  end

  local lockfile = require("claudecode.lockfile")
  local lock_success, lock_error = lockfile.remove(M.state.port)

  if not lock_success then
    vim.notify("Failed to remove lock file: " .. lock_error, vim.log.levels.WARN)
    -- Continue with shutdown even if lock file removal fails
  end

  if M.state.config.track_selection then
    local selection = require("claudecode.selection")
    selection.disable()
  end

  local success, error = M.state.server.stop()

  if not success then
    vim.notify("Failed to stop Claude Code integration: " .. error, vim.log.levels.ERROR)
    return false, error
  end

  M.state.server = nil
  M.state.port = nil

  vim.notify("Claude Code integration stopped", vim.log.levels.INFO)

  return true
end

--- Set up user commands
---@private
function M._create_commands()
  local logger = require("claudecode.logger")

  vim.api.nvim_create_user_command("ClaudeCodeStart", function()
    M.start()
  end, {
    desc = "Start Claude Code integration",
  })

  vim.api.nvim_create_user_command("ClaudeCodeStop", function()
    M.stop()
  end, {
    desc = "Stop Claude Code integration",
  })

  vim.api.nvim_create_user_command("ClaudeCodeStatus", function()
    if M.state.server and M.state.port then
      vim.notify("Claude Code integration is running on port " .. tostring(M.state.port), vim.log.levels.INFO)
    else
      vim.notify("Claude Code integration is not running", vim.log.levels.INFO)
    end
  end, {
    desc = "Show Claude Code integration status",
  })

  vim.api.nvim_create_user_command("ClaudeCodeSend", function(opts)
    if not M.state.server then
      logger.error("command", "ClaudeCodeSend: Claude Code integration is not running.")
      vim.notify("Claude Code integration is not running", vim.log.levels.ERROR)
      return
    end
    logger.debug(
      "command",
      "ClaudeCodeSend (new logic) invoked. Mode: "
        .. vim.fn.mode(true)
        .. ", Neovim's reported range: "
        .. tostring(opts and opts.range)
    )
    -- We now ignore opts.range and rely on the selection module's state,
    -- as opts.range was found to be 0 even when in visual mode for <cmd> mappings.

    if not M.state.server then
      logger.error("command", "ClaudeCodeSend: Claude Code integration is not running.")
      vim.notify("Claude Code integration is not running", vim.log.levels.ERROR, { title = "ClaudeCode Error" })
      return
    end

    local selection_module_ok, selection_module = pcall(require, "claudecode.selection")
    if selection_module_ok then
      local sent_successfully = selection_module.send_at_mention_for_visual_selection()
      if sent_successfully then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
        logger.debug("command", "ClaudeCodeSend: Exited visual mode after successful send.")

        -- Focus the Claude Code terminal after sending selection
        local terminal_ok, terminal = pcall(require, "claudecode.terminal")
        if terminal_ok then
          terminal.open({}) -- Open/focus the terminal
          logger.debug("command", "ClaudeCodeSend: Focused Claude Code terminal after selection send.")
        else
          logger.warn("command", "ClaudeCodeSend: Failed to load terminal module for focusing.")
        end
      end
    else
      logger.error("command", "ClaudeCodeSend: Failed to load selection module.")
      vim.notify("Failed to send selection: selection module not loaded.", vim.log.levels.ERROR)
    end
  end, {
    desc = "Send current visual selection as an at_mention to Claude Code",
    range = true, -- Important: This makes the command expect a range (visual selection)
  })

  local terminal_ok, terminal = pcall(require, "claudecode.terminal")
  if terminal_ok then
    vim.api.nvim_create_user_command("ClaudeCode", function(_opts)
      local current_mode = vim.fn.mode()
      if current_mode == "v" or current_mode == "V" or current_mode == "\22" then -- \22 is CTRL-V (blockwise visual mode)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
      end
      terminal.toggle_fallback_terminal() -- `opts.fargs` can be used for future enhancements.
    end, {
      nargs = "?",
      desc = "Toggle the Claude Code terminal window",
    })

    vim.api.nvim_create_user_command("ClaudeCodeOpen", function(_opts)
      terminal.open({})
    end, {
      nargs = "?",
      desc = "Open the Claude Code terminal window",
    })

    vim.api.nvim_create_user_command("ClaudeCodeClose", function()
      terminal.close()
    end, {
      desc = "Close the Claude Code terminal window",
    })
  else
    logger.error(
      "init",
      "Terminal module not found. Terminal commands (ClaudeCode, ClaudeCodeOpen, ClaudeCodeClose) not registered."
    )
  end
end

--- Get version information
---@return table Version information
function M.get_version()
  return {
    version = M.version:string(),
    major = M.version.major,
    minor = M.version.minor,
    patch = M.version.patch,
    prerelease = M.version.prerelease,
  }
end

return M
