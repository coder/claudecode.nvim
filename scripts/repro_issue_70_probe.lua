-- Issue #70 connection probe.
--
-- Starts the REAL claudecode WebSocket server (terminal provider "none", so this
-- process never launches Claude itself) and keeps it listening for the full
-- window, continuously writing its connection state to <status_file> as JSON.
-- Stops early if <stop_file> appears.
--
-- A separate harness (scripts/repro_issue_70.sh) launches the real Claude CLI
-- against the port reported here, under different environments, and reads the
-- status file to decide whether Claude actually connected. This isolates the bug
-- in issue #70 to a single observable fact: did Claude open a WebSocket back to
-- the plugin's server, or not?
--
-- Run: nvim --headless -u NONE -l scripts/repro_issue_70_probe.lua \
--          <repo_root> <status_file> <stop_file> <wait_ms>

local repo = arg[1]
local status_file = arg[2]
local stop_file = arg[3]
local wait_ms = tonumber(arg[4] or "120000")

package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path

local function write_status(tbl)
  local f = assert(io.open(status_file, "w"))
  f:write(vim.json.encode(tbl))
  f:close()
end

local function file_exists(p)
  local fd = io.open(p, "r")
  if fd then
    fd:close()
    return true
  end
  return false
end

local claudecode = require("claudecode")
claudecode.setup({ auto_start = true, terminal = { provider = "none" }, log_level = "debug" })

local port = claudecode.state and claudecode.state.port
if not port then
  write_status({ phase = "error", error = "server did not start / no port" })
  os.exit(1)
end

local config_dir = os.getenv("CLAUDE_CONFIG_DIR")
local lock_dir = (config_dir and config_dir ~= "" and (config_dir .. "/ide")) or (os.getenv("HOME") .. "/.claude/ide")
local lock_path = lock_dir .. "/" .. port .. ".lock"

io.stderr:write(
  ("PROBE listening port=%d lock=%s exists=%s\n"):format(port, lock_path, tostring(file_exists(lock_path)))
)
write_status({ phase = "listening", port = port, lock_path = lock_path, lock_exists = file_exists(lock_path) })

local server_module = require("claudecode.server.init")
local start = vim.loop.now()
local connected_ever = false
while (vim.loop.now() - start) < wait_ms do
  vim.wait(500, function()
    return false
  end) -- pump the libuv loop for ~500ms
  local st = server_module.get_status()
  local conn = claudecode.is_claude_connected()
  if conn then
    connected_ever = true
  end
  write_status({
    phase = conn and "connected" or "listening",
    port = port,
    lock_path = lock_path,
    lock_exists = file_exists(lock_path),
    connected = conn,
    connected_ever = connected_ever,
    client_count = st.client_count,
  })
  if file_exists(stop_file) then
    break
  end
end

io.stderr:write("PROBE done connected_ever=" .. tostring(connected_ever) .. "\n")
claudecode.stop() -- removes the lock file
os.exit(connected_ever and 0 or 2)
