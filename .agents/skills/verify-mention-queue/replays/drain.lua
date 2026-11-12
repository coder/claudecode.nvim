-- ReadyDelivers (the #480 drain finding): you send 100 mentions at once, as a tree add of 100 files does, while
-- Claude starts. Its handshake comes 8.6 s later. The queue drains to it 25 ms apart, past the deadline at 10.6 s,
-- and the deadline once cleared the rest while Claude was taking them. Now no deadline clears a mention while a ready
-- client is connected: all 100 must arrive, in order, with no error.
-- Model path: YouSend (each mention), ClaudeConnects(c), ClaudeUpgrades(c), HandshakeWritten(c), OpenRuns,
-- AcceptWaitPasses(c), HandshakeWaitPasses(c), FlushTimerFires, FlushRuns, DeadlineFires, DeadlineRuns, then
-- FlushTimerFires, FlushRuns for each mention.
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
L.setup()
local paths = {}
for index = 1, 100 do
  paths[index] = L.file("f" .. index .. ".txt")
end
for _, path in ipairs(paths) do
  require("claudecode").send_at_mention(path, nil, nil, "replay")
end
L.log("you send 100 mentions at once; queue=%d", L.queue_len())
L.wait(8600, "Claude starts")
local c = L.connect()
L.upgrade(c)
L.wait_for(8000, "the queue drains", function()
  return L.queue_len() == 0
end)
L.wait(200, "Claude reads the last frames")
local got = L.received(c)
local in_order = #got == 100
for index, path in ipairs(got) do
  in_order = in_order and path == paths[index]
end
L.log("Claude received %d, in order: %s; notices=%d", #got, tostring(in_order), #L.notices)
L.verdict(
  in_order and #L.notices == 0,
  "ReadyDelivers",
  string.format("100 at once, handshake at 8.6 s: received=%d errors=%d", #got, #L.notices)
)
