-- NoSilentDrop (finding 2, with a reconnect): Claude's socket drops during the 600 ms wait, and a new Claude
-- connects 2 s later. The mention must reach the new Claude, once, with no error.
-- Model path: YouSend, ClaudeConnects(1), ClaudeUpgrades(1), HandshakeWritten(1), OpenRuns, ClaudeDrops(1),
-- FlushTimerFires, FlushRuns, ClaudeConnects(2), ClaudeUpgrades(2), HandshakeWritten(2), OpenRuns,
-- AcceptWaitPasses(2), HandshakeWaitPasses(2), FlushTimerFires, FlushRuns.
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
L.setup()
L.send(L.file("hello.txt"))
local c = L.connect()
L.upgrade(c)
assert(dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/sync.lua")(L), "no armed flush")
L.drop(c)
L.wait(2000, "Claude restarts")
L.log("queue=%d connection timer=%s", L.queue_len(), L.timer_state())
local c2 = L.connect()
L.upgrade(c2)
L.wait(1500, "the 600 ms wait ends and the mention is sent")
local got = L.received(c2)
L.log("the new Claude received: %s; notices=%d", table.concat(got, ", "), #L.notices)
L.verdict(
  #got == 1 and #L.notices == 0,
  "NoSilentDrop",
  string.format("reconnect after a drop in the wait: new client received=%d errors=%d", #got, #L.notices)
)
