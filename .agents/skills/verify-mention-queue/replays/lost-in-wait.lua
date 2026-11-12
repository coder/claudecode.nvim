-- NoSilentDrop (finding 2): Claude's socket drops during the connection_wait_delay wait after its handshake. The
-- plugin once sent the mention to no client and logged success at debug level. Now the mention stays queued, and
-- with no new Claude it leaves at its deadline (connection_timeout + connection_wait_delay after the send) with the
-- connection timeout error.
-- Model path: YouSend, ClaudeConnects(c), ClaudeUpgrades(c), HandshakeWritten(c), OpenRuns, ClaudeDrops(c),
-- FlushTimerFires, FlushRuns, DeadlineFires, DeadlineRuns.
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
L.setup()
L.send(L.file("hello.txt"))
local c = L.connect()
L.upgrade(c)
assert(dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/sync.lua")(L), "no armed flush")
L.drop(c)
L.wait(1500, "the 600 ms wait ends")
local queued = L.queue_len()
L.log("after the wait: queue=%d; connection timer=%s", queued, L.timer_state())
L.wait(10000, "the deadline passes without a new Claude")
local got = L.received(c)
L.log("Claude received %d; queue=%d; notices=%d", #got, L.queue_len(), #L.notices)
L.verdict(
  queued == 1 and #got == 0 and #L.notices == 1 and L.notices[1]:find("Connection timeout", 1, true) ~= nil,
  "NoSilentDrop",
  string.format("drop in the wait: queued after it=%d received=%d errors=%d", queued, #got, #L.notices)
)
