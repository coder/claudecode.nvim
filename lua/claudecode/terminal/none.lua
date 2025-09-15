--- No-op terminal provider for Claude Code.
--- Performs zero UI actions and never manages terminals inside Neovim.
---@module 'claudecode.terminal.none'

---@type ClaudeCodeTerminalProvider
local M = {}

---Stored config (not used, but kept for parity with other providers)
---Setup the no-op provider
---@param term_config ClaudeCodeTerminalConfig
function M.setup(term_config)
  -- intentionally no-op
end

---Open terminal (no-op)
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
---@param focus boolean|nil
function M.open(cmd_string, env_table, effective_config, focus)
  -- intentionally no-op
end

---Close terminal (no-op)
function M.close()
  -- intentionally no-op
end

---Simple toggle (no-op)
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.simple_toggle(cmd_string, env_table, effective_config)
  -- intentionally no-op
end

---Focus toggle (no-op)
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.focus_toggle(cmd_string, env_table, effective_config)
  -- intentionally no-op
end

---Legacy toggle (no-op)
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.toggle(cmd_string, env_table, effective_config)
  -- intentionally no-op
end

---Ensure visible (no-op)
function M.ensure_visible() end

---Return active buffer number (always nil)
---@return number|nil
function M.get_active_bufnr()
  return nil
end

---Provider availability (always true; explicit opt-in required)
---@return boolean
function M.is_available()
  return true
end

---Testing hook (no state to return)
---@return table|nil
function M._get_terminal_for_test()
  return nil
end

return M
