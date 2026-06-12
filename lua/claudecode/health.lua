--- Health check for claudecode.nvim, run via :checkhealth claudecode
--- Verifies prerequisites (Neovim version, Claude CLI, terminal provider)
--- and reports live integration state (WebSocket server, lock file,
--- Claude connection) without launching anything.
---@module 'claudecode.health'
local M = {}

-- vim.health gained start/ok/warn/error in Neovim 0.10; older versions use report_* variants.
local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error_ = health.error or health.report_error
local info = health.info or health.report_info or ok

---Extracts the executable (first token) from a command string.
---@param cmd string
---@return string executable
local function executable_of(cmd)
  assert(type(cmd) == "string" and cmd ~= "", "cmd must be a non-empty string")
  return cmd:match("^(%S+)") or cmd
end

local function check_neovim()
  if vim.fn.has("nvim-0.8.0") == 1 then
    ok("Neovim >= 0.8.0")
  else
    error_("Neovim >= 0.8.0 is required")
  end
end

---@param claudecode table The main plugin module
local function check_setup(claudecode)
  if claudecode.state.initialized then
    ok("claudecode.nvim " .. claudecode.version:string() .. " is set up")
    return true
  end
  error_("setup() has not been called", { 'Call require("claudecode").setup() (or use your plugin manager\'s opts)' })
  return false
end

---@param config table The merged plugin config
local function check_cli(config)
  local terminal_cmd = config.terminal_cmd
  local cmd = (terminal_cmd and terminal_cmd ~= "") and terminal_cmd or "claude"
  local exe = executable_of(cmd)

  if vim.fn.executable(exe) ~= 1 then
    error_(("Claude CLI not found: '%s' is not executable"):format(exe), {
      "Install Claude Code: https://docs.anthropic.com/en/docs/claude-code",
      "Or set `terminal_cmd` in setup() to the full path of the CLI",
    })
    return
  end

  ok(("Claude CLI found: %s (%s)"):format(exe, vim.fn.exepath(exe)))

  local version_ok, output = pcall(vim.fn.system, { exe, "--version" })
  if version_ok and vim.v.shell_error == 0 then
    info("CLI version: " .. vim.trim(output))
  else
    warn(("'%s --version' failed; the configured command may not be the Claude CLI"):format(exe))
  end
end

---@param config table The merged plugin config
local function check_terminal_provider(config)
  local provider = config.terminal and config.terminal.provider or "auto"
  if type(provider) == "table" then
    info("Terminal provider: custom (table)")
    return
  end

  if provider == "auto" or provider == "snacks" then
    local has_snacks = pcall(require, "snacks")
    if has_snacks then
      ok(("Terminal provider '%s': snacks.nvim available"):format(provider))
    elseif provider == "snacks" then
      error_("Terminal provider 'snacks' configured but snacks.nvim is not installed")
    else
      ok("Terminal provider 'auto': snacks.nvim not installed, will fall back to native terminal")
    end
  elseif provider == "external" then
    local cmd = config.terminal.provider_opts and config.terminal.provider_opts.external_terminal_cmd
    if cmd and (type(cmd) == "function" or cmd:find("%%s")) then
      ok("Terminal provider 'external' configured")
    else
      error_("Terminal provider 'external' requires provider_opts.external_terminal_cmd containing '%s'")
    end
  else
    ok(("Terminal provider: %s"):format(provider))
  end
end

---@param claudecode table The main plugin module
local function check_server(claudecode)
  local server = require("claudecode.server.init")
  local status = server.get_status()

  if not status.running then
    warn("WebSocket server is not running", {
      "The server starts automatically when auto_start = true (default)",
      "Or start it manually with :ClaudeCodeStart",
    })
    return
  end

  ok(("WebSocket server running on port %d"):format(status.port))

  local lockfile = require("claudecode.lockfile")
  local lock_path = lockfile.lock_dir .. "/" .. tostring(status.port) .. ".lock"
  if vim.fn.filereadable(lock_path) == 1 then
    ok("Lock file present: " .. lock_path)
  else
    error_("Lock file missing: " .. lock_path, {
      "Claude discovers this Neovim instance through the lock file",
      "Restart the integration with :ClaudeCodeStop and :ClaudeCodeStart",
    })
  end

  if claudecode.is_claude_connected() then
    ok(("Claude Code is connected (%d client(s))"):format(status.client_count))
  else
    info("No Claude Code client connected yet (launch one with :ClaudeCode)")
  end
end

function M.check()
  start("claudecode.nvim")

  check_neovim()

  local loaded, claudecode = pcall(require, "claudecode")
  if not loaded then
    error_("Could not load claudecode module: " .. tostring(claudecode))
    return
  end

  if not check_setup(claudecode) then
    return
  end

  check_cli(claudecode.state.config)
  check_terminal_provider(claudecode.state.config)
  check_server(claudecode)
end

return M
