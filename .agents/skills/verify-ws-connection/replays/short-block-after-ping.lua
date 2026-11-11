-- Scenario: one main-loop block of 1.3 ping intervals that starts right after a ping was sent. The late tick after it can
-- run before the read of Claude's pong. Before #479 that tick dropped a Claude that answers every ping with 1011: the
-- block is below the wake threshold (interval * 1.5), so last_pong was not reset, and now - last_pong was about 2.3
-- intervals. Since #488 a tick never drops a client: only the keepalive check does, after the poll that read the pong.
-- Promise: a Claude that answers every ping is not dropped by such a block, and a Claude that stops answering is still
-- dropped, with 1006 for on_disconnect and Close 1011 for Claude.
-- Model path: TimerTicks (a ping), Claude answers, TimerTicks (a ping, Neovim blocks), Claude's pong stays unread,
-- TimerTicks (a ping, the tick stamps nothing new and drops nothing), PollAndCheck (the pong is read, the stamp clears).
-- The block runs in a libuv check callback, which runs after the poll phase of the loop iteration that ran the timer. So
-- the socket read comes only after the next tick. With libuv 1.44 (Neovim 0.8) any block does that. With newer libuv a
-- block in a check or I/O callback does, and a block in vim.schedule or a timer callback reads the socket first.
local H = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
local INTERVAL, BLOCK = 200, 260 -- ms: BLOCK / INTERVAL = 1.3, below the 1.5 wake threshold
local SETTLE, SILENT = 1500, 3000 -- ms: how long Claude must stay listed, and how long a silent Claude gets to be dropped

local plugin = H.start_plugin(INTERVAL)
H.log("plugin: server on port %d, ping timer every %d ms", plugin.port, INTERVAL)
local claude = H.peer(plugin.port)
claude.answer_pings = true
claude.connect(function()
  claude.hello(plugin.token)
end)
H.wait(5000, function()
  local client = plugin.client()
  return client and client.state == "connected" and claude.count(H.frame.OPCODE.PING) >= 3
end)
local client = assert(plugin.client(), "no client")
H.log("claude: connected and answered %d pings", claude.count(H.frame.OPCODE.PING))

-- Right after the timer callback sent the next ping (last_ping changes), in the same loop iteration and before the next
-- poll phase can read Claude's pong, block the loop for 1.3 intervals.
local seen, blocked = client.last_ping, false
local check = H.uv.new_check()
check:start(function()
  if not blocked and client.last_ping ~= seen then
    blocked = true
    check:stop()
    H.log("plugin: a ping was just sent; the main loop blocks for %d ms (%.1f intervals)", BLOCK, BLOCK / INTERVAL)
    H.uv.sleep(BLOCK)
  end
end)

H.wait(SETTLE, function()
  return #plugin.disconnects > 0
end)
local dropped = plugin.disconnects[1]
H.log(
  "claude: %d pings, Close frames %s, EOF %s",
  claude.count(H.frame.OPCODE.PING),
  vim.inspect(claude.close_frames()),
  tostring(claude.eof)
)
H.check("the block happened", blocked, "blocked = " .. tostring(blocked))
H.check(
  "Claude, which answers every ping, is not dropped by one 1.3-interval block",
  dropped == nil and plugin.client() ~= nil,
  dropped and string.format("on_disconnect(%s, %s, %q) at %d ms", dropped.id, dropped.code, dropped.reason, dropped.at)
    or string.format("no on_disconnect in %d ms, still listed", SETTLE)
)

-- Claude stops answering: it is still dropped, at the first read after the third tick that follows its first unanswered ping.
claude.answer_pings = false
local silent_at = H.ms()
H.log("claude: stops answering pings")
H.wait(SILENT, function()
  return #plugin.disconnects > 0
end)
H.wait(500, function()
  return claude.eof
end)
local silent = plugin.disconnects[1]
H.check(
  "a Claude that stops answering is still dropped, with Close 1011",
  silent ~= nil
    and silent.code == 1006
    and silent.reason == "Connection timeout"
    and vim.deep_equal(claude.close_frames(), { "1011" }),
  silent
      and string.format(
        "on_disconnect(%s, %s, %q) %.1f intervals after Claude went silent, Close frames %s",
        silent.id,
        silent.code,
        silent.reason,
        (silent.at - silent_at) / INTERVAL,
        table.concat(claude.close_frames(), ",")
      )
    or string.format("no on_disconnect in %d ms", SILENT)
)
H.finish()
