-- FlushDelivers (finding 7): you send between Claude's TCP connect and its WebSocket handshake. The plugin once
-- flushed only on the TCP connect, so nothing flushed after the handshake, and the timeout cleared the mention while
-- Claude was connected. Now the handshake schedules the flush: the mention must arrive once, with no error.
-- Model path: ClaudeConnects(c), YouSend, ClaudeUpgrades(c), HandshakeWritten(c), OpenRuns, AcceptWaitPasses(c),
-- HandshakeWaitPasses(c), FlushTimerFires, FlushRuns.
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
L.setup()
local path = L.file("hello.txt")
local c = L.connect()
L.wait(50, "Claude has not asked for the WebSocket yet")
L.send(path)
L.upgrade(c)
L.wait(1500, "connection_wait_delay ends and the flush runs")
local got = L.received(c)
L.log("Claude received %d; queue=%d; client=%s; notices=%d", #got, L.queue_len(), L.server_clients(), #L.notices)
L.verdict(
  #got == 1 and #L.notices == 0 and L.queue_len() == 0,
  "FlushDelivers",
  string.format("send before the handshake: received=%d errors=%d", #got, #L.notices)
)
