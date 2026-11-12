-- NothingAfterStop (finding 4): :ClaudeCodeStop during the connection_wait_delay wait. A deferred send once indexed
-- M.state.server after M.stop set it to nil, and raised a Lua error. Now the stop clears the queue and stops its
-- timers: no Lua error, and Claude gets nothing.
-- Model path: YouSend, ClaudeConnects(c), ClaudeUpgrades(c), HandshakeWritten(c), OpenRuns, YouStop.
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
local cc = L.setup()
L.send(L.file("hello.txt"))
local c = L.connect()
L.upgrade(c)
assert(dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/sync.lua")(L), "no armed flush")
L.log("you run :ClaudeCodeStop")
vim.cmd("ClaudeCodeStop")
L.log("server=%s queue=%d errmsg=%q", tostring(cc.state.server), L.queue_len(), L.errmsg())
L.wait(1500, "the 600 ms wait ends")
local err = L.errmsg()
L.log("v:errmsg = %s", err)
L.verdict(
  err == "" and #L.received(c) == 0,
  "NothingAfterStop",
  string.format("Lua error after stop: %s", err:match("init%.lua:%d+: [^\n]*") or err)
)
