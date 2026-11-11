-- NoStrandedMention (the #480 churn finding): clients connect and leave without overlap, a new one every 1000 ms
-- that stays 300 ms, so none is ever ready. Each handshake once stopped the connection timeout, and the mention
-- waited with no error for as long as the clients kept coming. Now no handshake moves the mention's deadline: it
-- must leave with one error about connection_timeout + connection_wait_delay (10.6 s) after the send, and no client
-- may get it.
-- Model path: ClaudeConnects(c), ClaudeUpgrades(c), HandshakeWritten(c), OpenRuns, YouSend, ClaudeDrops(c),
-- FlushTimerFires, FlushRuns, then the same connect and drop again, until DeadlineFires, DeadlineRuns.
local uv = vim.uv or vim.loop
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
L.setup()
local path = L.file("hello.txt")
local clients, sent_at, cleared_at = {}, nil, nil
local function now()
  return uv.hrtime() / 1e6
end
for round = 1, 14 do
  local started = now()
  local c = L.connect()
  L.upgrade(c)
  table.insert(clients, c)
  if round == 1 then
    L.send(path)
    sent_at = now()
  end
  L.wait(300 - (now() - started), "this client stays 300 ms")
  L.drop(c)
  if not cleared_at and L.queue_len() == 0 then
    cleared_at = now()
  end
  L.wait(1000 - (now() - started), "the next client connects 1000 ms after this one")
  if not cleared_at and L.queue_len() == 0 then
    cleared_at = now()
  end
end
local received = 0
for _, c in ipairs(clients) do
  received = received + #L.received(c)
end
local after = cleared_at and (cleared_at - sent_at) or -1
L.log("queue=%d; notices=%d; received=%d; cleared %.0f ms after the send", L.queue_len(), #L.notices, received, after)
L.verdict(
  L.queue_len() == 0 and #L.notices == 1 and received == 0 and after >= 10600 and after < 12000,
  "NoStrandedMention",
  string.format("clients that never overlap: errors=%d received=%d cleared after %.0f ms", #L.notices, received, after)
)
