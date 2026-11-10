-- Fixture for issue #283:
--   "find_available_port probe-then-rebind races; create_server has no retry ->
--    EADDRINUSE with parallel Neovim instances (regression in #282)"
--   https://github.com/coder/claudecode.nvim/issues/283
--
-- This fixture starts the REAL claudecode WebSocket server on launch and prints
-- a big banner showing whether THIS instance got a listening port or failed.
--
-- Reproduction (from repo root), in TWO terminals:
--   source fixtures/nvim-aliases.sh
--   vv issue-283      # terminal 1 -> "LISTENING on port 48811"
--   vv issue-283      # terminal 2 -> "FAILED ... Failed to listen on port 48811: EADDRINUSE"
--
-- Because #282 dropped the per-process RNG seeding, every fresh Neovim picks the
-- SAME port (48811 with the default 10000-65535 range), so the second instance
-- always collides. The probe in find_available_port cannot notice the first
-- instance's listener (libuv defers EADDRINUSE to listen()), and create_server
-- does not retry, so the integration never starts in instance 2.
--
-- :ReproStatus  re-print this instance's server status
-- :ReproStop    stop this instance's server (frees the port / lockfile)

local config_dir = vim.fn.stdpath("config")
local repo_root = vim.fn.fnamemodify(config_dir, ":h:h")
vim.opt.rtp:prepend(repo_root)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
vim.o.showtabline = 0
vim.o.laststatus = 2

local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

-- auto_start = false so we can call start() ourselves and capture its result.
claudecode.setup({
  auto_start = false,
  log_level = "info",
  terminal = {
    provider = "native",
    auto_close = false,
  },
})

local started_ok, started_info = claudecode.start(false)

local function status_lines()
  local running = claudecode.state and claudecode.state.server ~= nil
  local port = claudecode.state and claudecode.state.port or nil
  local lines = {
    "claudecode.nvim -- issue #283 reproduction fixture",
    "",
    "Run `vv issue-283` in a SECOND terminal while this one is open.",
    "",
  }
  if started_ok and running then
    lines[#lines + 1] = "THIS INSTANCE: ✅ server LISTENING on port " .. tostring(port)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Now open a second instance: it should FAIL on the same port"
    lines[#lines + 1] = "with EADDRINUSE, because every fresh Neovim deterministically"
    lines[#lines + 1] = "selects this same port (lost RNG seeding in #282)."
  else
    lines[#lines + 1] = "THIS INSTANCE: ❌ server FAILED to start"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  " .. tostring(started_info)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "This is #283: another Neovim already holds this port, the probe"
    lines[#lines + 1] = "could not detect it, and create_server did not retry."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ":ReproStatus  re-print status     :ReproStop  stop this server"
  return lines, (started_ok and running)
end

local function show_banner()
  local lines, good = status_lines()
  vim.bo.modifiable = true
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.modifiable = false
  vim.bo.modified = false
  -- Keep the echo SHORT (port only) so it stays below the hit-enter threshold;
  -- the full error text lives in the banner buffer above.
  local msg = good and ("issue283: LISTENING on port " .. tostring(claudecode.state.port))
    or "issue283: FAILED -- port in use (EADDRINUSE); see buffer above"
  vim.api.nvim_echo({ { msg, good and "MoreMsg" or "ErrorMsg" } }, false, {})
end

vim.api.nvim_create_user_command("ReproStatus", show_banner, { desc = "Re-print #283 server status" })
vim.api.nvim_create_user_command("ReproStop", function()
  claudecode.stop()
  vim.api.nvim_echo({ { "issue283: server stopped", "MoreMsg" } }, false, {})
end, { desc = "Stop this instance's server (#283)" })

-- Populate the buffer synchronously at load time so it is already non-empty when
-- startup finishes -- this suppresses Neovim's intro screen without depending on
-- a deferred redraw (a hit-enter prompt from the plugin's own error log can
-- otherwise block a scheduled callback). The plugin's native error message still
-- appears in the message area, exactly as a real user sees it.
show_banner()
