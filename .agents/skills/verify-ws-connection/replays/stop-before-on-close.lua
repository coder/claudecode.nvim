-- Scenario: the server stops between Claude's Close frame and the vim.schedule'd on_close. Before #455 nothing closed the
-- plugin's socket, which stayed in CLOSE_WAIT until Neovim exited.
-- Promise: every socket the plugin is done with gets closed. A stop reports no client (M.stop rejects the pending
-- diffs itself), and the socket of the client that it dropped still closes.
-- Model path: Accept, Read (upgrade request), WriteDone (101), Read (Claude's Close: the reply is written, the state is
-- "closing", on_close is scheduled), ServerStops, ScheduledRuns (on_close: _disconnect_client finds no client and
-- closes its socket), ReadEOF (Claude hung up).
local H = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")

local plugin = H.start_plugin(nil)
H.log("plugin: server on port %d", plugin.port)

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
local claude_port = claude.tcp:getsockname().port
H.log("claude: %s; plugin: %s is %s", tostring(claude.status_line), client.id, client.state)

-- A libuv check handle runs right after the poll phase in which the plugin read Claude's Close frame, before the
-- main loop runs the scheduled on_close. It stops the server there: server/init.lua M.stop, the call that init.lua
-- M.stop (:ClaudeCodeStop) makes. The rest of init.lua M.stop (lock file, selection, mention queue) does not touch
-- clients.
local stopped
local check = H.uv.new_check()
check:start(function()
  if client.state == "closing" and not stopped then
    stopped = true
    check:stop()
    H.log("plugin: read Claude's Close frame (state %s); the server stops before on_close runs", client.state)
    local ok, err = plugin.srv.stop()
    H.log("plugin: server/init.lua M.stop() = %s %s", tostring(ok), tostring(err))
  end
end)

claude.send(H.frame.OPCODE.CLOSE, string.char(0x03, 0xE8) .. "bye")
H.wait(2000, function()
  return claude.count(H.frame.OPCODE.CLOSE) > 0
end)
H.log("claude: got Close %s back, and closes its socket", table.concat(claude.close_frames(), ","))
claude.tcp:close()

H.wait(1000)
H.check(
  "the server stopped between the Close frame and on_close",
  stopped == true and plugin.srv.state.server == nil,
  "server/init.lua M.state.server = " .. tostring(plugin.srv.state.server)
)
H.check(
  "the stop reported no client",
  #plugin.disconnects == 0,
  string.format("%d on_disconnect calls", #plugin.disconnects)
)
H.check(
  "the plugin's socket is closed 1 s after Claude closed its end",
  client.tcp_handle:is_closing(),
  string.format(
    "tcp_handle:is_closing() = %s, fileno = %s",
    tostring(client.tcp_handle:is_closing()),
    tostring(client.tcp_handle:fileno())
  )
)
local state = H.tcp_state(plugin.port, claude_port)
H.check(
  "the kernel does not hold it in CLOSE_WAIT",
  state ~= "CLOSE_WAIT",
  string.format("/proc/net/tcp: 127.0.0.1:%d <- :%d is %s", plugin.port, claude_port, state)
)
H.finish()
