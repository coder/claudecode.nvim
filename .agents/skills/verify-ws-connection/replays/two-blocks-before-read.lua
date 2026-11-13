-- Scenario: the main loop blocks twice in a row, each time for 1.3 ping intervals (interval 200 ms), starting right
-- after a ping: first in a libuv check callback, then in a vim.schedule callback. Claude runs in a process of its own and
-- answers every ping at once, so its pongs wait in the socket for the whole 2.6 intervals. On Neovim 0.8 (libuv 1.44)
-- libuv runs the timers at the end of a pass and again at the start of the next one, with the vim.schedule block
-- between them: two ticks run with no read of Claude's socket between them. Before the keepalive check (#488) the
-- second tick dropped Claude: #479 pinged again at the first tick that found no pong and dropped at the second.
-- Promise: a Claude that answers every ping is not dropped, and a Claude that stops answering is still dropped.
-- Model path: TimerTicks, TimerTicks (Claude answered before each, the plugin read none), PollAndCheck (the poll reads the
-- pongs, and the check finds the stamp cleared). Without JudgesAfterRead the second or third tick drops Claude.
-- Newer Neovim (libuv 1.52) reads the socket between these two blocks, so the replay passes there on the old code too.
local H = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
local INTERVAL, BLOCK = 200, 260 -- ms: BLOCK / INTERVAL = 1.3
local SETTLE, SILENT = 2000, 3000 -- ms: how long Claude must stay listed, and how long a silent Claude gets to be dropped

local plugin = H.start_plugin(INTERVAL)
H.log("plugin: server on port %d, ping timer every %d ms", plugin.port, INTERVAL)
local claude = H.spawn_claude(plugin.port, plugin.token)
local seen, pings = 0, 0
H.wait(8000, function()
  local client = plugin.client()
  if client and client.state == "connected" and client.last_ping ~= seen then
    seen, pings = client.last_ping, pings + 1
  end
  return pings >= 4
end)
local client = assert(plugin.client(), "no client")
H.log("claude: connected, %d pings seen", pings)

-- Right after the timer callback sent the next ping (last_ping changes), in the same loop iteration, block for 1.3
-- intervals in this check callback. A vim.schedule callback queued from it then blocks for 1.3 intervals again.
seen = client.last_ping
local blocks = 0
local check = H.uv.new_check()
check:start(function()
  if blocks == 0 and client.last_ping ~= seen then
    check:stop()
    H.log("plugin: a ping was just sent; block %d ms (%.1f intervals) in a check callback", BLOCK, BLOCK / INTERVAL)
    H.uv.sleep(BLOCK)
    blocks = 1
    vim.schedule(function()
      H.log("plugin: block %d ms in vim.schedule", BLOCK)
      H.uv.sleep(BLOCK)
      blocks = 2
    end)
  end
end)

H.wait(SETTLE, function()
  return #plugin.disconnects > 0
end)
local dropped = plugin.disconnects[1]
H.check("both blocks happened", blocks == 2, "blocks = " .. blocks)
H.check(
  "Claude, which answers every ping, is not dropped by two 1.3-interval blocks",
  dropped == nil and plugin.client() ~= nil,
  dropped and string.format("on_disconnect(%s, %s, %q) at %d ms", dropped.id, dropped.code, dropped.reason, dropped.at)
    or string.format("no on_disconnect in %d ms, still listed", SETTLE)
)

-- Claude stops answering: it is still dropped.
claude.silence()
local silent_at = H.ms()
H.log("claude: stops answering pings")
H.wait(SILENT, function()
  return #plugin.disconnects > 0
end)
local silent = plugin.disconnects[1]
H.check(
  'a Claude that stops answering is still dropped, with 1006 "Connection timeout"',
  silent ~= nil and silent.at > silent_at and silent.code == 1006 and silent.reason == "Connection timeout",
  silent
      and string.format(
        "on_disconnect(%s, %s, %q) %.1f intervals after Claude went silent",
        silent.id,
        silent.code,
        silent.reason,
        (silent.at - silent_at) / INTERVAL
      )
    or string.format("no on_disconnect in %d ms", SILENT)
)
claude.kill()
H.finish()
