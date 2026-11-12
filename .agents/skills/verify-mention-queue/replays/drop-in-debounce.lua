-- NoStrandedMention (finding 6): Claude's socket drops within the 50 ms debounce after a send while it was connected.
-- The connected path once started no timer, so the mention waited with nothing that sent or dropped it. Now its
-- deadline runs from the send: with no new Claude, the mention leaves with the connection timeout error.
-- Model path: ClaudeConnects(c), ClaudeUpgrades(c), HandshakeWritten(c), OpenRuns, AcceptWaitPasses(c),
-- HandshakeWaitPasses(c), YouSend, ClaudeDrops(c), FlushTimerFires, FlushRuns, DeadlineFires, DeadlineRuns.
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
L.setup()
local path = L.file("hello.txt")
local c = L.connect()
L.upgrade(c)
L.wait(800, "Claude is ready: connection_wait_delay passed since its handshake")
L.send(path)
L.drop(c)
L.wait_for(11500, "the deadline clears the mention", function()
  return L.queue_len() == 0 and #L.notices > 0
end)
L.log(
  "queue=%d; connection timer=%s; notices=%d; received=%d",
  L.queue_len(),
  L.timer_state(),
  #L.notices,
  #L.received(c)
)
L.verdict(
  L.queue_len() == 0 and #L.notices == 1 and #L.received(c) == 0 and L.timer_state() == "nil",
  "NoStrandedMention",
  string.format("dropped during the debounce: queue=%d errors=%d timer=%s", L.queue_len(), #L.notices, L.timer_state())
)
