-- Scenario: a tick gap while Claude's handshake is still in flight. Before #455 the gap counted against Claude, and the
-- ping timer dropped it with 1011 one interval after its handshake, before any ping reached it.
-- Promise: a Claude that answers every ping is never dropped. The 101 write callback starts its keepalive window.
-- Model path: Accept, TimerTicksAfterGap (the client is still connecting), Read (the upgrade request), WriteDone (101,
-- connected), TimerTicks (a ping, not a drop).
local H = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
local INTERVAL, STALL, WAIT = 200, 700, 2000 -- ms; the plugin's default interval is 30000, a gap is above interval * 1.5

local plugin = H.start_plugin(INTERVAL)
H.log("plugin: server on port %d, ping timer every %d ms", plugin.port, INTERVAL)

-- A libuv check handle runs after the poll phase in which the listener accepted the connection, before the read of
-- Claude's upgrade request. It blocks the main loop there, as a suspended or busy Neovim would.
local accepted_at, stalled
local check = H.uv.new_check()
check:start(function()
  local client = plugin.client()
  if client and not stalled then
    stalled = true
    accepted_at = H.ms()
    H.log("plugin: accepted %s (state %s); Neovim's main loop now blocks for %d ms", client.id, client.state, STALL)
    H.uv.sleep(STALL)
    check:stop()
  end
end)

local claude = H.peer(plugin.port)
claude.answer_pings = true
claude.connect(function()
  H.log("claude: connected, sends its upgrade request at once")
  claude.hello(plugin.token)
end)

-- Claude answers every ping, so the plugin must keep it for at least ten intervals after the gap.
H.wait(WAIT, function()
  return #plugin.disconnects > 0
end)
local d = plugin.disconnects[1]
H.log("claude: status line %q at %s ms", tostring(claude.status_line), tostring(claude.opened_at))
H.log(
  "claude: got %d pings, Close frames %s, then EOF: %s",
  claude.count(H.frame.OPCODE.PING),
  vim.inspect(claude.close_frames()),
  tostring(claude.eof)
)

H.check(
  "the gap fell inside the handshake",
  stalled == true and claude.opened and claude.opened_at > accepted_at,
  string.format("101 at %s ms, accept at %s ms, block %d ms", tostring(claude.opened_at), tostring(accepted_at), STALL)
)
H.check(
  "Claude is not dropped",
  d == nil and plugin.client() ~= nil and not claude.eof,
  d and string.format("on_disconnect(%s, %s, %q) at %d ms", d.id, d.code, d.reason, d.at)
    or string.format("no on_disconnect in %d ms (%d intervals), still listed", WAIT, math.floor(WAIT / INTERVAL))
)
H.check(
  "Claude is pinged, and gets no Close frame",
  claude.count(H.frame.OPCODE.PING) >= 3 and #claude.close_frames() == 0,
  string.format(
    "%d pings, Close frames %s",
    claude.count(H.frame.OPCODE.PING),
    table.concat(claude.close_frames(), ",")
  )
)
H.finish()
