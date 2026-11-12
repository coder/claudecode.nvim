-- NoSilentDrop (finding 1): you send while Claude is not connected, and Claude completes its handshake 4.6 s later, as
-- a cold start often does. The plugin once dropped such a mention as older than queue_timeout at the flush, with no
-- error. Now the mention waits for Claude: it must arrive once, with no error.
-- Model path: YouSend, ClaudeConnects(c), ClaudeUpgrades(c), HandshakeWritten(c), OpenRuns, AcceptWaitPasses(c),
-- HandshakeWaitPasses(c), FlushTimerFires, FlushRuns.
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
L.setup()
L.send(L.file("hello.txt"))
L.wait(4600, "Claude starts slowly")
local c = L.connect()
L.upgrade(c)
L.wait(1500, "connection_wait_delay ends and the flush runs")
local got = L.received(c)
L.log("Claude received %d; queue=%d; notices=%d", #got, L.queue_len(), #L.notices)
L.verdict(
  #got == 1 and #L.notices == 0 and L.queue_len() == 0,
  "NoSilentDrop",
  string.format("slow start: received=%d errors=%d queue=%d", #got, #L.notices, L.queue_len())
)
