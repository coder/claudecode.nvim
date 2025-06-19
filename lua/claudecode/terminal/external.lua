--- External terminal provider for Claude Code.
-- This provider does nothing - it assumes Claude Code is running in an external terminal.
-- @module claudecode.terminal.external

--- @type TerminalProvider
local M = {}

local logger = require("claudecode.logger")

--- Configures the external terminal provider (no-op).
-- @param term_config table The terminal configuration (ignored).
function M.setup(term_config)
  logger.info(
    "terminal",
    "External terminal provider configured - Claude Code commands will not launch internal terminals"
  )
  logger.debug("terminal", "External provider setup complete - assuming external Claude Code instance will connect")
end

--- Opens the Claude terminal (no-op for external provider).
-- @param cmd_string string The command to run (ignored).
-- @param env_table table Environment variables (ignored).
-- @param effective_config table Terminal configuration (ignored).
-- @param focus boolean|nil Whether to focus the terminal (ignored).
function M.open(cmd_string, env_table, effective_config, focus)
  logger.debug(
    "terminal",
    "External terminal provider: open() called - no action taken (assuming external Claude Code)"
  )
end

--- Closes the managed Claude terminal (no-op for external provider).
function M.close()
  logger.debug("terminal", "External terminal provider: close() called - no action taken")
end

--- Simple toggle: show/hide the Claude terminal (no-op for external provider).
-- @param cmd_string string The command to run (ignored).
-- @param env_table table Environment variables (ignored).
-- @param effective_config table Terminal configuration (ignored).
function M.simple_toggle(cmd_string, env_table, effective_config)
  logger.debug("terminal", "External terminal provider: simple_toggle() called - no action taken")
end

--- Smart focus toggle: switches to terminal if not focused, hides if currently focused (no-op for external provider).
-- @param cmd_string string The command to run (ignored).
-- @param env_table table Environment variables (ignored).
-- @param effective_config table Terminal configuration (ignored).
function M.focus_toggle(cmd_string, env_table, effective_config)
  logger.debug("terminal", "External terminal provider: focus_toggle() called - no action taken")
end

--- Toggles the Claude terminal open or closed (no-op for external provider).
-- @param cmd_string string The command to run (ignored).
-- @param env_table table Environment variables (ignored).
-- @param effective_config table Terminal configuration (ignored).
function M.toggle(cmd_string, env_table, effective_config)
  logger.debug("terminal", "External terminal provider: toggle() called - no action taken")
end

--- Gets the buffer number of the currently active Claude Code terminal.
-- For external provider, this always returns nil since there's no managed terminal.
-- @return nil Always returns nil for external provider.
function M.get_active_bufnr()
  return nil
end

--- Checks if the external terminal provider is available.
-- The external provider is always available.
-- @return boolean Always returns true.
function M.is_available()
  return true
end

--- Gets the managed terminal instance for testing purposes (external provider has none).
-- @return nil Always returns nil for external provider.
function M._get_terminal_for_test()
  return nil
end

return M
