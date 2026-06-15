-- Reproduction / verification for issue #283:
--   "find_available_port probe-then-rebind races; create_server has no retry ->
--    EADDRINUSE with parallel Neovim instances (regression in #282)"
--   https://github.com/coder/claudecode.nvim/issues/283
--
-- WHAT ACTUALLY BROKE (more than the issue's own analysis):
--
--   1. LOST RNG SEEDING (the regression trigger, NEW in #282).
--      Before #282, find_available_port shuffled the port list via
--      utils.shuffle_array, which calls `math.randomseed(os.time())` the first
--      time it runs. So every Neovim process seeded its PRNG and picked a
--      different starting port (as long as two instances did not start in the
--      same wall-clock second).
--      #282 replaced the shuffle with a direct, UNSEEDED `math.random(port_count)`
--      and dropped the `require("claudecode.server.utils")` line, so nothing
--      seeds the PRNG anymore. LuaJIT's math.random has a FIXED default seed, so
--      EVERY fresh Neovim process now computes the IDENTICAL start_offset -> the
--      IDENTICAL port (48811 with the default 10000-65535 range). Two instances
--      therefore ALWAYS collide, deterministically, regardless of timing.
--
--   2. BROKEN PROBE (pre-existing, but now always hit). find_available_port
--      probes a candidate by binding a THROWAWAY socket, closing it, and
--      returning the port. libuv's uv_tcp_bind SWALLOWS EADDRINUSE: instead of
--      failing, it stores the error as a `delayed_error` and returns success,
--      deferring the failure to listen()/connect(). The probe never listens, so
--      its bind "succeeds" even when another process is actively LISTENING on the
--      port -> the probe reports a taken port as available.
--
--   3. NO RETRY (pre-existing, but now always hit). create_server selects the
--      port once; the deferred EADDRINUSE then surfaces at listen() (hence the
--      user's error text "Failed to listen on port ...", NOT "Failed to bind"),
--      and create_server gives up instead of advancing to the next port.
--
-- This script proves mechanism (2)+(3) deterministically in a single process,
-- and exposes the deterministic port (1) for the cross-process check driven by
-- scripts/repro_issue_283.sh.
--
-- Run from the repo root:
--   nvim --headless -u NONE -l scripts/repro_issue_283.lua            # mechanism proof
--   REPRO283_MODE=port  nvim --headless -u NONE -l scripts/repro_issue_283.lua
--   REPRO283_MODE=serve REPRO283_LABEL=A nvim --headless -u NONE -l scripts/repro_issue_283.lua
--
-- Exit code (mechanism mode): 1 if the broken probe + listen-time EADDRINUSE
-- reproduce (#283 confirmed), 0 if the probe correctly rejects a busy port.

local script_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ":h:h")
vim.opt.rtp:prepend(repo_root)

local function out(msg)
  io.stdout:write(msg .. "\n")
  io.stdout:flush()
end

-- luv returns 0 (or a handle) on success and nil+err on failure. 0 is TRUTHY in
-- Lua, which is exactly why find_available_port's `if success then` accepts it.
local function ok_truthy(v)
  return v and true or false
end

local uv = vim.loop
local mode = vim.env.REPRO283_MODE or "mechanism"

-- Match a real startup's PRNG draw order: requiring server/init.lua performs the
-- module-load draw `module_instance_id = math.random(10000, 99999)` BEFORE
-- find_available_port's own draw, so the port we compute equals what a real
-- :ClaudeCodeStart selects (48811 with the default range).
require("claudecode.server.init")
local tcp = require("claudecode.server.tcp")
local config = { port_range = { min = 10000, max = 65535 } }

-------------------------------------------------------------------------------
-- MODE: port  -- print the deterministically-selected port, then exit.
-- The harness runs this in several fresh processes and asserts they all match.
-------------------------------------------------------------------------------
if mode == "port" then
  local port = tcp.find_available_port(config.port_range.min, config.port_range.max)
  out("SELECTED_PORT=" .. tostring(port))
  vim.cmd("qa!")
  return
end

-------------------------------------------------------------------------------
-- MODE: serve -- start the REAL server (create_server) and stay alive, exactly
-- as lua/claudecode/server/init.lua does. Used for the two-instance end-to-end
-- reproduction.
-------------------------------------------------------------------------------
if mode == "serve" then
  local label = vim.env.REPRO283_LABEL or "?"
  local wait_ms = tonumber(vim.env.REPRO283_WAIT_MS or "") or 6000
  local server, err = tcp.create_server(config, {}, nil)
  if server then
    out(("INSTANCE_%s: LISTENING port=%d"):format(label, server.port))
  else
    -- Mirror the exact init.lua user-facing wording.
    out(
      ("INSTANCE_%s: [ClaudeCode] [init] [ERROR] Failed to start Claude Code server: %s"):format(label, tostring(err))
    )
  end
  vim.wait(wait_ms, function()
    return false
  end)
  if server then
    tcp.stop_server(server)
  end
  vim.cmd("qa!")
  return
end

-------------------------------------------------------------------------------
-- MODE: mechanism (default) -- in-process, deterministic proof that the probe
-- cannot detect an active listener and that EADDRINUSE surfaces at listen().
-------------------------------------------------------------------------------
out("== issue #283 reproduction (broken probe + listen-time EADDRINUSE) ==")
out(("Neovim: %s"):format(tostring(vim.version())))

-- Stand up a real, actively-LISTENING socket on an OS-assigned free port.
local listener = uv.new_tcp()
listener:bind("127.0.0.1", 0)
local listen_ok = listener:listen(128, function() end)
assert(ok_truthy(listen_ok), "harness: could not start listener")
local P = listener:getsockname().port
out(("\nA real server is now LISTENING on 127.0.0.1:%d"):format(P))

-- STEP 1: run find_available_port's exact probe against the busy port.
local probe = uv.new_tcp()
local probe_bind = probe:bind("127.0.0.1", P)
probe:close()
local probe_says_available = ok_truthy(probe_bind)
out(
  ("\n[probe] throwaway bind to busy port %d -> %s  => find_available_port would treat it as %s"):format(
    P,
    tostring(probe_bind),
    probe_says_available and "AVAILABLE (FALSE POSITIVE)" or "taken (correct)"
  )
)

-- STEP 2: reproduce create_server's bind-then-listen on that same busy port.
local real = uv.new_tcp()
local bind_ok, bind_err = real:bind("127.0.0.1", P)
out(("[create_server] bind   to busy port %d -> ok=%s err=%s"):format(P, tostring(bind_ok), tostring(bind_err)))
local lst_ok, lst_err = real:listen(128, function() end)
out(("[create_server] listen on busy port %d -> ok=%s err=%s"):format(P, tostring(lst_ok), tostring(lst_err)))

local listen_failed_eaddrinuse = (not ok_truthy(lst_ok)) and (tostring(lst_err):match("EADDRINUSE") ~= nil)

-- Cleanup
if not real:is_closing() then
  real:close()
end
if not listener:is_closing() then
  listener:close()
end

out("\n== verdict ==")
out(
  ("  probe false-positive : %s"):format(
    probe_says_available and "YES -- probe says a LISTENING port is available" or "no"
  )
)
out(
  ("  bind swallowed error : %s"):format(ok_truthy(bind_ok) and "YES -- bind() returned success on a busy port" or "no")
)
out(
  ("  listen() EADDRINUSE   : %s"):format(
    listen_failed_eaddrinuse and "YES -- error surfaces at listen(), matching the user's report" or "no"
  )
)

local reproduced = probe_says_available and listen_failed_eaddrinuse
if reproduced then
  out(
    "\n=> #283 confirmed: the probe cannot detect an active listener (libuv defers EADDRINUSE\n"
      .. "   to listen()), so find_available_port returns a busy port and create_server fails\n"
      .. "   at listen() with no retry. Combined with the lost RNG seeding (see repro .sh),\n"
      .. "   every parallel Neovim instance deterministically collides on the same port."
  )
else
  out("\n=> NOT reproduced: the probe correctly rejected the busy port on this platform/libuv build.")
end

io.stdout:flush()
vim.cmd("cquit " .. (reproduced and 1 or 0))
