-- NoStrandedMention (finding 6): Claude's CLOSE frame sets the client to "closing". is_claude_connected once still
-- counted it, so a send in that tick took the connected path, and the mention waited with nothing that sent or
-- dropped it. Now a closing client does not count, and the mention's deadline runs from the send: with no new
-- Claude, it leaves with the connection timeout error. The replay feeds the CLOSE frame through the real
-- server/client.lua process_data, with the on_close that server/tcp.lua passes, and sends in the same tick.
-- Model path: ClaudeConnects(c), ClaudeUpgrades(c), HandshakeWritten(c), OpenRuns, ClaudeCloses(c), YouSend,
-- CloseCallbackRuns(c), DeadlineFires, DeadlineRuns.
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
L.setup()
local path = L.file("hello.txt")
local c = L.connect()
L.upgrade(c)
local server = require("claudecode.server.init").state.server
local client_mod = require("claudecode.server.client")
local frame = require("claudecode.server.frame")
local tcp = require("claudecode.server.tcp")
local _, srv_client = next(server.clients)
client_mod.process_data(
  srv_client,
  frame.create_frame(frame.OPCODE.CLOSE, "\3\232", true, true),
  function() end,
  function(cl, code, reason)
    tcp._disconnect_client(server, cl, code, reason)
  end,
  function() end,
  require("claudecode").state.auth_token
)
L.log("Claude's CLOSE frame arrives: server-side state=%s", srv_client.state)
L.send(path)
L.log(
  "ClaudeCodeSendComplete fired %d time(s); queue=%d; connection timer=%s",
  L.send_complete,
  L.queue_len(),
  L.timer_state()
)
L.wait_for(11500, "the deadline clears the mention", function()
  return L.queue_len() == 0 and #L.notices > 0
end)
L.log(
  "Claude received %d; queue=%d; client=%q; connection timer=%s; notices=%d",
  #L.received(c),
  L.queue_len(),
  L.server_clients(),
  L.timer_state(),
  #L.notices
)
L.verdict(
  L.send_complete == 0 and L.queue_len() == 0 and #L.notices == 1 and L.timer_state() == "nil",
  "NoStrandedMention",
  string.format(
    "sent to a closing client: completes=%d queue=%d errors=%d timer=%s",
    L.send_complete,
    L.queue_len(),
    #L.notices,
    L.timer_state()
  )
)
