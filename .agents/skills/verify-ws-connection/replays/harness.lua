-- Shared helpers for the verify-ws-connection replays. The plugin side is the real code: require("claudecode")
-- setup and start, the real server, its real ping timer (at a short interval), real sockets on 127.0.0.1. Only
-- Claude is played, by a luv TCP client in the same Neovim that speaks RFC 6455 with masked frames.
-- A replay runs a scenario in which the model found a bug (see SKILL.md, "Bugs this model found") and checks the
-- promise that the fix keeps. Each check prints KEPT or BROKEN, and the run exits 0 only when every check is kept.
local uv = vim.uv or vim.loop
local frame = require("claudecode.server.frame")
local utils = require("claudecode.server.utils")

local M = {}
local start_ns = uv.hrtime()
local kept, total, skipped = 0, 0, 0

function M.ms()
  return math.floor((uv.hrtime() - start_ns) / 1e6)
end

function M.log(fmt, ...)
  io.stdout:write(string.format("[%5d ms] " .. fmt .. "\n", M.ms(), ...))
end

-- One line per result, and a count line from finish().
function M.check(name, ok, detail)
  total = total + 1
  if ok then
    kept = kept + 1
  end
  io.stdout:write(string.format("%s %s: %s\n", ok and "KEPT" or "BROKEN", name, detail))
end

-- A check that this host cannot run. It counts as neither kept nor broken.
function M.skip(name, detail)
  skipped = skipped + 1
  io.stdout:write(string.format("SKIPPED %s: %s\n", name, detail))
end

function M.finish()
  io.stdout:write(
    string.format("%d of %d kept%s\n", kept, total, skipped > 0 and string.format(", %d skipped", skipped) or "")
  )
  io.stdout:flush()
  vim.cmd(kept == total and "qa!" or "cq!")
end

function M.wait(ms, cond)
  return vim.wait(ms, cond or function()
    return false
  end, 5)
end

-- Start the plugin as a user does (setup, then start). With interval, replace the 30 s ping timer by the real
-- tcp.start_ping_timer at that interval. Counts on_disconnect calls without changing what they do.
function M.start_plugin(interval)
  require("claudecode").setup({
    auto_start = false,
    log_level = "warn",
    track_selection = false,
    terminal = { provider = "none" },
  })
  local ok, port = require("claudecode").start(false)
  assert(ok, tostring(port))
  local srv = require("claudecode.server.init")
  if interval then
    srv.state.ping_timer:stop()
    srv.state.ping_timer:close()
    srv.state.ping_timer = require("claudecode.server.tcp").start_ping_timer(srv.state.server, interval)
  end
  local plugin = { port = port, token = require("claudecode").state.auth_token, srv = srv, disconnects = {} }
  local on_disconnect = srv.state.server.on_disconnect
  srv.state.server.on_disconnect = function(client, code, reason)
    table.insert(plugin.disconnects, { id = client.id, code = code, reason = reason, at = M.ms() })
    M.log("plugin: on_disconnect(%s, %s, %q)", client.id, tostring(code), tostring(reason))
    return on_disconnect(client, code, reason)
  end
  function plugin.client()
    local _, client = next(srv.state.server.clients)
    return client
  end
  return plugin
end

-- Claude. Received frames are kept as { opcode, code (Close frames), at }.
function M.peer(port)
  local p = { frames = {}, chunks = {}, size = 0, opened = false, eof = false, answer_pings = false }
  p.tcp = uv.new_tcp()

  function p.feed(data)
    table.insert(p.chunks, data)
    p.size = p.size + #data
    while p.size > 0 and (not p.need or p.size >= p.need) do
      local raw = table.concat(p.chunks)
      if not p.opened then
        local i = raw:find("\r\n\r\n", 1, true)
        if not i then
          p.chunks = { raw }
          return
        end
        p.status_line = raw:match("^[^\r]*")
        p.opened = true
        p.opened_at = M.ms()
        raw = raw:sub(i + 4)
      end
      local f, consumed, code, detail = frame.parse_frame(raw)
      if not f then
        assert(not code, "server frame broke the protocol: " .. tostring(detail))
        p.need = detail
        p.chunks, p.size = { raw }, #raw
        return
      end
      p.need = nil
      raw = raw:sub(consumed + 1)
      p.chunks, p.size = { raw }, #raw
      local got = { opcode = f.opcode, at = M.ms() }
      if f.opcode == frame.OPCODE.CLOSE and #f.payload >= 2 then
        got.code = f.payload:byte(1) * 256 + f.payload:byte(2)
      end
      table.insert(p.frames, got)
      if f.opcode == frame.OPCODE.PING and p.answer_pings then
        p.send(frame.OPCODE.PONG, f.payload)
      end
    end
  end

  function p.start_reading()
    p.tcp:read_start(function(err, data)
      if err or not data then
        p.eof = true
        return
      end
      p.feed(data)
    end)
  end

  function p.stop_reading()
    p.tcp:read_stop()
  end

  function p.hello(token)
    p.tcp:write(table.concat({
      "GET / HTTP/1.1",
      "Host: 127.0.0.1:" .. port,
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: " .. utils.generate_websocket_key(),
      "Sec-WebSocket-Version: 13",
      "x-claude-code-ide-authorization: " .. token,
      "",
      "",
    }, "\r\n"))
  end

  function p.send(opcode, payload)
    p.tcp:write(frame.create_frame(opcode, payload, true, true))
  end

  function p.count(opcode)
    local n = 0
    for _, f in ipairs(p.frames) do
      if f.opcode == opcode then
        n = n + 1
      end
    end
    return n
  end

  function p.close_frames()
    local out = {}
    for _, f in ipairs(p.frames) do
      if f.opcode == frame.OPCODE.CLOSE then
        table.insert(out, tostring(f.code))
      end
    end
    return out
  end

  function p.connect(on_connect)
    p.tcp:connect("127.0.0.1", port, function(err)
      assert(not err, err)
      p.connected = true
      p.start_reading()
      if on_connect then
        on_connect()
      end
    end)
  end

  return p
end

-- Claude in a process of its own: a second headless Neovim that runs claude-process.lua, connects, and answers every
-- ping at once, whatever blocks this Neovim. The in-process Claude of M.peer answers only when this Neovim's loop runs,
-- so it cannot show a plugin that blocks for a few intervals. `mode` is "big:<n>:<bytes>" (at ping n, send a text frame of
-- that many bytes before the pong) or "late:<n>:<ms>" (sleep that long before the pong of ping n, as a machine that
-- sleeps with Neovim does). `silence()` makes it stop answering. `kill()` ends it.
function M.spawn_claude(port, token, mode)
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local flag = vim.fn.tempname()
  local env = {}
  for k, v in pairs(vim.fn.environ()) do
    table.insert(env, k .. "=" .. v)
  end
  vim.list_extend(env, {
    "VWC_HARNESS=" .. here .. "/harness.lua",
    "VWC_PEER_PORT=" .. port,
    "VWC_PEER_TOKEN=" .. token,
    "VWC_PEER_SILENT_FLAG=" .. flag,
    "VWC_PEER_MODE=" .. (mode or ""),
  })
  local proc = uv.spawn(vim.v.progpath, {
    args = {
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "--cmd",
      "lua vim.opt.rtp:prepend(os.getenv('VWC_REPO'))",
      "-c",
      "luafile " .. here .. "/claude-process.lua",
    },
    env = env,
  }, function() end)
  assert(proc, "could not start the Claude process")
  local claude = {}
  function claude.silence()
    io.open(flag, "w"):close()
  end
  function claude.kill()
    proc:kill("sigterm")
    os.remove(flag)
  end
  return claude
end

-- The kernel's TCP state of the plugin's end of the connection to Claude's local port (from /proc/net/tcp), "gone"
-- when no such connection is listed, and nil on a host without /proc/net/tcp (macOS, BSD).
function M.tcp_state(server_port, peer_port)
  local file = io.open("/proc/net/tcp", "r")
  if not file then
    return nil
  end
  local names =
    { ["01"] = "ESTABLISHED", ["06"] = "TIME_WAIT", ["07"] = "CLOSE", ["08"] = "CLOSE_WAIT", ["09"] = "LAST_ACK" }
  local want_local, want_remote = string.format(":%04X", server_port), string.format(":%04X", peer_port)
  for line in file:lines() do
    local loc, rem, st = line:match("^%s*%d+: (%x+:%x+) (%x+:%x+) (%x%x)")
    if loc and loc:sub(-5) == want_local and rem:sub(-5) == want_remote then
      file:close()
      return names[st] or st
    end
  end
  file:close()
  return "gone"
end

M.frame = frame
M.uv = uv
return M
