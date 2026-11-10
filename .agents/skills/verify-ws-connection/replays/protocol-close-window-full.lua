-- Scenario: Claude stops reading, a large message fills its receive window, and Claude sends a frame that breaks the
-- protocol. Before #455 the client stayed in server.clients, in state "closing", for as long as Claude did not read:
-- is_claude_connected() stayed true and on_disconnect (the diff cleanup) did not run.
-- Promise: a client the plugin closes is reported once and leaves server.clients at once, and its Close frame is still
-- delivered before its socket closes.
-- Model path: Accept, Read (upgrade request), WriteDone (101), ClaudeStopsReading, PluginSendsLarge, Read (the bad
-- frame: close_client queues its Close frame, on_error reports the client), then Claude reads again.
local H = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
local INTERVAL = 200 -- ms; the keepalive drops a silent connected client after about 3 ticks (600 ms)

local plugin = H.start_plugin(INTERVAL)
H.log("plugin: server on port %d, ping timer every %d ms", plugin.port, INTERVAL)

local claude = H.peer(plugin.port)
claude.answer_pings = true
claude.connect(function()
  claude.hello(plugin.token)
end)
H.wait(2000, function()
  local client = plugin.client()
  return claude.opened and client and client.state == "connected"
end)
local client = assert(plugin.client(), "no client")
H.log("claude: %s; plugin: %s is %s", tostring(claude.status_line), client.id, client.state)

-- Claude stops reading and answering. The plugin sends it a message (a notification with a large field) until
-- Claude's receive window is full and the rest waits in libuv's write queue.
claude.stop_reading()
claude.answer_pings = false
local sent = 0
local blob = string.rep("x", 4 * 1024 * 1024)
while client.tcp_handle:get_write_queue_size() == 0 and sent < 64 do
  plugin.srv.broadcast("test/large", { blob = blob })
  sent = sent + 4
  H.wait(20)
end
H.log(
  "plugin: sent %d MiB to Claude; %d bytes wait in libuv's write queue",
  sent,
  client.tcp_handle:get_write_queue_size()
)
assert(client.tcp_handle:get_write_queue_size() > 0, "Claude's window did not fill")

-- Claude sends a binary frame, which the plugin does not accept (close 1003). The client must leave at once, with
-- no help from Claude, whose window stays full.
claude.send(H.frame.OPCODE.BINARY, "not text")
H.wait(1000, function()
  return #plugin.disconnects > 0
end)
local wait_ms = 10 * INTERVAL
H.wait(wait_ms)
local listed = plugin.srv.state.server.clients[client.id] == client
local status = plugin.srv.get_status()
local d = plugin.disconnects[1]
H.log("plugin: %s is %s after the binary frame", client.id, client.state)

H.check(
  "the client left server.clients and was reported once, while Claude does not read",
  not listed and status.client_count == 0 and #plugin.disconnects == 1 and d.code == 1006,
  string.format(
    "listed=%s, client_count=%d, on_disconnect calls=%d, %d ms after the binary frame",
    tostring(listed),
    status.client_count,
    #plugin.disconnects,
    wait_ms
  )
)
H.check(
  "the plugin no longer counts Claude as connected",
  require("claudecode").is_claude_connected() == false,
  "require('claudecode').is_claude_connected() = " .. tostring(require("claudecode").is_claude_connected())
)
H.check(
  "its socket stays open for the Close frame, which waits in libuv's queue",
  not client.tcp_handle:is_closing() and client.tcp_handle:get_write_queue_size() > 0,
  string.format(
    "is_closing()=%s, %d bytes in libuv's write queue",
    tostring(client.tcp_handle:is_closing()),
    client.tcp_handle:get_write_queue_size()
  )
)

-- Claude reads again: the queued writes and the Close frame go out, and only then does the socket close.
claude.start_reading()
H.wait(10000, function()
  return claude.count(H.frame.OPCODE.CLOSE) > 0 and client.tcp_handle:is_closing()
end)
H.check(
  "Claude gets the Close frame (1003) once it reads, and then the socket closes",
  vim.deep_equal(claude.close_frames(), { "1003" }) and client.tcp_handle:is_closing(),
  string.format(
    "Close frames %s, is_closing()=%s",
    table.concat(claude.close_frames(), ","),
    tostring(client.tcp_handle:is_closing())
  )
)
H.check(
  "Claude's reading again reports nothing more",
  #plugin.disconnects == 1,
  string.format("%d on_disconnect call(s)", #plugin.disconnects)
)
H.finish()
