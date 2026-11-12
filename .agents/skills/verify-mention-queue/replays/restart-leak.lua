-- NothingAfterStop (finding 4, restart form): :ClaudeCodeStop then :ClaudeCodeStart during the connection_wait_delay
-- wait, and a new Claude connects. The mention from before the stop once reached the new Claude. Now the stop clears
-- it: the new Claude must get nothing.
-- Model path: YouSend, ClaudeConnects(1), ClaudeUpgrades(1), HandshakeWritten(1), OpenRuns, YouStop, YouStart,
-- ClaudeConnects(2), ClaudeUpgrades(2), HandshakeWritten(2), OpenRuns.
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
L.setup()
L.send(L.file("hello.txt"))
local c = L.connect()
L.upgrade(c)
assert(dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/sync.lua")(L), "no armed flush")
L.log("you run :ClaudeCodeStop, then :ClaudeCodeStart")
vim.cmd("ClaudeCodeStop")
vim.cmd("ClaudeCodeStart")
local c2 = L.connect()
L.upgrade(c2)
L.wait(1500, "the 600 ms wait ends")
local got = L.received(c2)
L.log("the new Claude received: %s; v:errmsg=%q", table.concat(got, ", "), L.errmsg())
L.verdict(#got == 0, "NothingAfterStop", string.format("sent across a stop: new client received=%d", #got))
