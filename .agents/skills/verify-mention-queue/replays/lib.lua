-- Shared helpers for the mention-queue replays. Each replay runs in a fresh headless Neovim (see run.sh), starts
-- the real plugin with the default delays and the "none" terminal provider, and plays Claude with real loopback
-- WebSocket clients in the same process. Every step of a replay is one model action, in the model's order, and
-- vim.wait pumps the real event loop between steps, so the plugin's own timers and vim.schedule callbacks run.
-- The auth token is read from plugin state and never printed.
local uv = vim.uv or vim.loop
local L = {}

local start = uv.hrtime()
local function ms()
  return math.floor((uv.hrtime() - start) / 1e6)
end

function L.log(fmt, ...)
  io.stdout:write(string.format("%6d ms  ", ms()) .. string.format(fmt, ...) .. "\n")
end

-- What the user sees: every vim.notify at WARN or above, and every Lua error Neovim reports.
L.notices = {}
local notify = vim.notify
vim.notify = function(msg, level, opts)
  if (level or 0) >= vim.log.levels.WARN then
    table.insert(L.notices, msg)
    L.log("user sees: %s", msg)
  end
  return notify(msg, level, opts)
end
L.send_complete = 0

function L.setup()
  local cc = require("claudecode")
  cc.setup({ terminal = { provider = "none" }, track_selection = false })
  assert(cc.state.server, "the server did not start")
  vim.api.nvim_create_autocmd("User", {
    pattern = "ClaudeCodeSendComplete",
    callback = function()
      L.send_complete = L.send_complete + 1
    end,
  })
  L.log(
    "plugin started: connection_timeout=%d connection_wait_delay=%d",
    cc.state.config.connection_timeout,
    cc.state.config.connection_wait_delay
  )
  return cc
end

function L.wait(n, why)
  L.log("wait %d ms (%s)", n, why)
  vim.wait(n, function()
    return false
  end, 10)
end

function L.wait_for(n, why, cond)
  local ok = vim.wait(n, cond, 5)
  L.log("%s: %s", why, ok and "yes" or "NO (timed out)")
  return ok
end

-- A file that exists, given as an absolute path, the way :ClaudeCodeAdd passes it after expand.
function L.file(name)
  local path = vim.fn.getcwd() .. "/" .. name
  vim.fn.writefile({ name }, path)
  return path
end

function L.send(path)
  local cc = require("claudecode")
  local connected = cc.is_claude_connected()
  local ok, err = cc.send_at_mention(path, nil, nil, "replay")
  L.log(
    "you send %s (Claude counts as connected: %s): ok=%s%s",
    vim.fn.fnamemodify(path, ":t"),
    tostring(connected),
    tostring(ok),
    err and (" err=" .. err) or ""
  )
end

function L.queue_len()
  return #require("claudecode").state.mention_queue
end

function L.server_clients()
  local status = require("claudecode.server.init").get_status()
  local out = {}
  for _, info in ipairs(status.clients or {}) do
    table.insert(out, info.state)
  end
  table.sort(out)
  return table.concat(out, ",")
end

function L.client_count()
  return #(require("claudecode.server.init").get_status().clients or {})
end

function L.timer_state()
  local t = require("claudecode").state.connection_timer
  if not t then
    return "nil"
  end
  return t:is_active() and "running" or "set but not running"
end

-- Claude, played by a loopback client.
function L.connect()
  local cc = require("claudecode")
  local before = L.client_count()
  local c = { tcp = uv.new_tcp(), buf = "", upgraded = false, texts = {}, eof = false }
  c.tcp:connect("127.0.0.1", cc.state.port, function(err)
    assert(not err, err)
    c.tcp:read_start(function(rerr, data)
      if rerr or not data then
        c.eof = true
        return
      end
      c.buf = c.buf .. data
      if not c.upgraded then
        local head_end = c.buf:find("\r\n\r\n", 1, true)
        if not head_end then
          return
        end
        c.status = c.buf:match("^HTTP/1%.1 (%d+)")
        c.upgraded = c.status == "101"
        c.buf = c.buf:sub(head_end + 4)
      end
      while #c.buf >= 2 do
        local b1, b2 = c.buf:byte(1, 2)
        local len, pos = b2 % 128, 3
        if len == 126 then
          if #c.buf < 4 then
            return
          end
          len, pos = c.buf:byte(3) * 256 + c.buf:byte(4), 5
        end
        if #c.buf < pos + len - 1 then
          return
        end
        if b1 % 16 == 1 then
          table.insert(c.texts, c.buf:sub(pos, pos + len - 1))
        end
        c.buf = c.buf:sub(pos + len)
      end
    end)
  end)
  L.wait_for(2000, "Claude opens its socket; the server lists it", function()
    return L.client_count() > before
  end)
  return c
end

function L.upgrade(c)
  local token = require("claudecode").state.auth_token
  local key = require("claudecode.server.utils").base64_encode("0123456789abcdef")
  c.tcp:write(table.concat({
    "GET / HTTP/1.1",
    "Host: 127.0.0.1",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key,
    "Sec-WebSocket-Version: 13",
    "x-claude-code-ide-authorization: " .. token,
    "",
    "",
  }, "\r\n"))
  -- Claude reads the 101 reply after its write finished, and the write callback marked the client connected.
  return L.wait_for(2000, "Claude asks for the WebSocket; the handshake completes", function()
    return c.upgraded and L.server_clients():find("connected", 1, true) ~= nil
  end)
end

-- The at_mentioned file paths Claude received, in order.
function L.received(c)
  local out = {}
  for _, text in ipairs(c.texts) do
    local ok, msg = pcall(vim.json.decode, text)
    if ok and msg.method == "at_mentioned" then
      table.insert(out, msg.params.filePath)
    end
  end
  return out
end

function L.drop(c)
  local before = L.client_count()
  c.tcp:read_stop()
  c.tcp:close()
  L.wait_for(2000, "Claude's socket drops; the server forgets the client", function()
    return L.client_count() < before
  end)
end

-- The last Lua error Neovim reported (a vim.schedule or vim.defer_fn callback that raised), or "".
function L.errmsg()
  return vim.v.errmsg
end

-- One verdict line per replay: KEPT or BROKEN, the rule whose promise the replay checks, and the facts it rests on.
function L.verdict(kept, rule, facts)
  io.stdout:write(string.format("%s %s: %s\n", kept and "KEPT" or "BROKEN", rule, facts))
  vim.cmd("qall!")
end

return L
