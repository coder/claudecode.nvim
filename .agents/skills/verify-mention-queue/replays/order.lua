-- SentInOrder (finding 3): you send mention 1 while Claude is not connected, Claude connects, and you send mention 2
-- during the connection_wait_delay wait. Mention 2 once took the 50 ms debounce path and overtook mention 1. Now one
-- queue holds both: Claude must get mention 1, then mention 2.
-- Model path: YouSend, ClaudeConnects(c), ClaudeUpgrades(c), HandshakeWritten(c), OpenRuns, YouSend,
-- AcceptWaitPasses(c), HandshakeWaitPasses(c), FlushTimerFires, FlushRuns, FlushTimerFires, FlushRuns.
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
L.setup()
L.send(L.file("first.txt"))
local c = L.connect()
L.upgrade(c)
assert(dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/sync.lua")(L), "no armed flush")
L.send(L.file("second.txt"))
L.wait(1500, "the debounce and the 600 ms wait end")
local got = L.received(c)
L.log("Claude received, in order: %s", table.concat(got, " | "))
local in_order = #got == 2 and got[1]:find("first.txt", 1, true) ~= nil and got[2]:find("second.txt", 1, true) ~= nil
L.verdict(
  in_order,
  "SentInOrder",
  string.format(
    "arrival order: %s",
    table.concat(
      vim.tbl_map(function(p)
        return vim.fn.fnamemodify(p, ":t")
      end, got),
      ", "
    )
  )
)
