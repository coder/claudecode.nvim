--- RFC 6455 lets a client split one message into fragments: a TEXT frame with FIN clear, CONTINUATION frames, and a
--- last CONTINUATION frame with FIN set. Only the whole text must be valid UTF-8, and a fragment may end inside a code
--- point. JSON-RPC travels as text, so the plugin refuses binary messages.
require("tests.busted_setup")

local client = require("claudecode.server.client")
local frame = require("claudecode.server.frame")

local TEXT, BINARY, CONTINUATION = frame.OPCODE.TEXT, frame.OPCODE.BINARY, frame.OPCODE.CONTINUATION

describe("WebSocket client messages", function()
  local c, writes, messages, errors

  before_each(function()
    writes, messages, errors = {}, {}, {}
    local handle = { closed = false }
    function handle:write(data, callback)
      table.insert(writes, { data = data, closing = self.closed })
      if callback then
        callback()
      end
    end
    function handle:close()
      self.closed = true
    end
    function handle:is_closing()
      return self.closed
    end
    c = { id = "test_client", tcp_handle = handle, state = "connected", buffer = "", handshake_complete = true }
  end)

  -- The client masks every frame it sends.
  local function frames(...)
    local data = {}
    for _, spec in ipairs({ ... }) do
      table.insert(data, frame.create_frame(spec[1], spec[2], spec[3] ~= false, true))
    end
    return table.concat(data)
  end

  local function receive(data)
    client.process_data(c, data, function(_, message)
      table.insert(messages, message)
    end, function() end, function(_, err)
      table.insert(errors, err)
      c.tcp_handle:close()
    end)
  end

  ---@return integer|nil code The status of the Close frame the plugin wrote while the socket was still open
  ---@return string|nil reason The reason text of that Close frame
  local function close_code()
    for _, w in ipairs(writes) do
      local parsed = frame.parse_frame(w.data)
      if parsed and parsed.opcode == frame.OPCODE.CLOSE then
        assert.is_false(w.closing, "the Close frame was written after the socket closed")
        return parsed.payload:byte(1) * 256 + parsed.payload:byte(2), parsed.payload:sub(3)
      end
    end
  end

  local request = '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"uri":"file:///x\240\159\152\128"}}'
  local split_in_emoji = #'{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"uri":"file:///x' + 2

  it("delivers a text message whose fragments split a code point, once and whole", function()
    receive(frames({ TEXT, request:sub(1, split_in_emoji), false }, { CONTINUATION, request:sub(split_in_emoji + 1) }))

    assert.same({ request }, messages)
    assert.is_nil(close_code())
  end)

  it("delivers a message in three fragments split at ASCII bytes, once and whole", function()
    receive(frames({ TEXT, request:sub(1, 10), false }, { CONTINUATION, request:sub(11, 40), false }, {
      CONTINUATION,
      request:sub(41),
    }))

    assert.same({ request }, messages)
    assert.is_nil(close_code())
  end)

  it("answers a ping between fragments and still delivers the message", function()
    receive(frames({ TEXT, request:sub(1, split_in_emoji), false }, { frame.OPCODE.PING, "hi" }, {
      CONTINUATION,
      request:sub(split_in_emoji + 1),
    }))

    assert.same({ request }, messages)
    local pong = frame.parse_frame(writes[1].data)
    assert.same({ frame.OPCODE.PONG, "hi" }, { pong.opcode, pong.payload })
  end)

  it("delivers fragments that arrive in separate reads", function()
    local data = frames(
      { TEXT, request:sub(1, split_in_emoji), false },
      { CONTINUATION, request:sub(split_in_emoji + 1) }
    )
    for i = 1, #data, 7 do
      receive(data:sub(i, i + 6))
    end

    assert.same({ request }, messages)
  end)

  it("closes with 1007 when a continuation frame holds a UTF-16 surrogate", function()
    receive(frames({ TEXT, '{"uri":"', false }, { CONTINUATION, '\237\160\128"}' }))

    assert.same({}, messages)
    assert.equals(1007, close_code())
  end)

  it("closes with 1007 when a message ends inside a code point", function()
    receive(frames({ TEXT, request:sub(1, split_in_emoji), false }, { CONTINUATION, "" }))

    assert.same({}, messages)
    assert.equals(1007, close_code())
  end)

  -- RFC 6455 requires UTF-8 as RFC 3629 defines it, which has none of these byte sequences.
  for _, case in ipairs({
    { "an overlong 2-byte form of '/'", "\192\175" },
    { "an overlong 3-byte form of '/'", "\224\128\175" },
    { "an overlong 4-byte form of '/'", "\240\128\128\175" },
    { "a UTF-16 surrogate (U+D800)", "\237\160\128" },
    { "a code point above U+10FFFF", "\244\144\128\128" },
    { "the lead byte F5", "\245\128\128\128" },
    { "the lead byte FF", "\255\128\128\128" },
  }) do
    it("closes with 1007 for an unfragmented text message with " .. case[1], function()
      receive(frames({ TEXT, "ok " .. case[2] }))

      assert.same({}, messages)
      assert.equals(1007, close_code())
    end)
  end

  it("delivers the first and last code point of each UTF-8 length", function()
    -- U+0000, U+007F, U+0080, U+07FF, U+0800, U+D7FF, U+E000, U+FFFD, U+10000 and U+10FFFF
    local text =
      "\0 \127 \194\128 \223\191 \224\160\128 \237\159\191 \238\128\128 \239\191\189 \240\144\128\128 \244\143\191\191"
    receive(frames({ TEXT, text }))

    assert.same({ text }, messages)
  end)

  it("closes with 1003 on a binary message and does not run it", function()
    receive(frames({ BINARY, request }))

    assert.same({}, messages)
    assert.equals(1003, close_code())
  end)

  it("closes with 1002 on a continuation frame with no message to continue", function()
    receive(frames({ CONTINUATION, request }))

    assert.same({}, messages)
    assert.equals(1002, close_code())
  end)

  it("closes with 1002 when a binary frame comes inside a fragmented text message", function()
    receive(frames({ TEXT, request:sub(1, 10), false }, { BINARY, request }))

    assert.same({}, messages)
    assert.equals(1002, close_code())
  end)

  -- RFC 6455 section 7.4.1 names each status. The reason text tells the client which rule its data broke.
  for _, case in ipairs({
    { 1002, "Protocol error", "a continuation frame with no message", { CONTINUATION, "{}" } },
    { 1003, "Unsupported data", "a binary message", { BINARY, "{}" } },
    { 1007, "Invalid frame payload data", "a text message that is not UTF-8", { TEXT, "\255" } },
  }) do
    it("sends the reason text " .. case[2] .. " with " .. case[1] .. " for " .. case[3], function()
      receive(frames(case[4]))

      assert.same({ case[1], case[2] }, { close_code() })
    end)
  end

  it("sends the reason text Invalid frame payload data with 1007 for a close reason that is not UTF-8", function()
    receive(frames({ frame.OPCODE.CLOSE, "\3\232\255" }))

    assert.same({ 1007, "Invalid frame payload data" }, { close_code() })
  end)

  it("sends the reason text Message too big with 1009 for a frame over the limit", function()
    -- A BINARY frame header with a 64-bit length of 200 MiB. The limit applies before any payload arrives.
    receive(string.char(0x82, 0x7F) .. string.rep("\0", 4) .. string.char(0x0C, 0x80, 0x00, 0x00))

    assert.same({ 1009, "Message too big" }, { close_code() })
  end)

  -- The rule goes to on_error, which the server logs as the disconnect reason at debug level.
  local PING, CLOSE = frame.OPCODE.PING, frame.OPCODE.CLOSE
  for _, case in ipairs({
    { "Reserved opcode 0x3", frame.create_frame(0x3, "", true, true) },
    { "Reserved bits set", string.char(0xC1, 0x80) .. "\0\0\0\0" },
    { "Fragmented control frame", frame.create_frame(PING, "", false, true) },
    { "Control frame over 125 bytes", frame.create_frame(PING, string.rep("a", 126), true, true) },
    { "WebSocket frame too big", string.char(0x82, 0x7F) .. string.rep("\0", 4) .. string.char(0x0C, 0, 0, 0) },
    { "Close frame with a 1-byte payload", frame.create_frame(CLOSE, "\3", true, true) },
    { "Invalid UTF-8 in close reason", frame.create_frame(CLOSE, "\3\232\255", true, true) },
  }) do
    it("names the broken rule " .. case[1] .. " when it closes for a frame", function()
      receive(case[2])

      assert.same({ case[1] }, errors)
    end)
  end

  it("receives a large frame in many reads with memory linear in its size", function()
    local payload = '{"jsonrpc":"2.0","id":1,"method":"tools/list"' .. string.rep(" ", 512 * 1024) .. "}"
    local data = frame.create_frame(TEXT, payload, true, true)
    local reads = {}
    for i = 1, #data, 1024 do
      table.insert(reads, data:sub(i, i + 1023))
    end
    -- JIT traces and the coverage line hook allocate too. Without them, the count is what the server allocates.
    -- jit.off() keeps the traces that earlier tests compiled, so jit.flush() drops them.
    local hook, mask, hook_count = debug.gethook()
    local jit_was_on = jit and jit.status()
    debug.sethook()
    if jit then
      jit.off()
      jit.flush()
    end
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    local ok, err = pcall(function()
      for _, read in ipairs(reads) do
        receive(read)
      end
    end)
    local allocated_kib = collectgarbage("count") - before
    collectgarbage("restart")
    if jit_was_on then
      jit.on()
    end
    debug.sethook(hook, mask, hook_count)
    assert(ok, err)

    assert.same({ payload }, messages)
    -- Unmasking costs about 16 bytes per payload byte, 8 MiB here. Joining each 1 KiB read onto the bytes before it
    -- copies 128 MiB.
    assert.is_true(allocated_kib < 32768, string.format("allocated %.0f KiB", allocated_kib))
  end)

  it("handles many small frames in one read with memory linear in their number", function()
    local count = 4000
    local data = string.rep(frames({ TEXT, "{}" }), count)
    -- JIT traces and the coverage line hook allocate too. Without them, the count is what the server allocates.
    -- jit.off() keeps the traces that earlier tests compiled, and they still run. Here they allocated up to 5 MiB more
    -- in some runs, so jit.flush() drops them.
    local hook, mask, hook_count = debug.gethook()
    local jit_was_on = jit and jit.status()
    debug.sethook()
    if jit then
      jit.off()
      jit.flush()
    end
    collectgarbage("collect")
    collectgarbage("stop")
    local before = collectgarbage("count")
    local ok, err = pcall(receive, data)
    local allocated_kib = collectgarbage("count") - before
    collectgarbage("restart")
    if jit_was_on then
      jit.on()
    end
    debug.sethook(hook, mask, hook_count)
    assert(ok, err)

    assert.equals(count, #messages)
    -- About 1 KiB per frame. Cutting the rest of the 32 KB read off after each frame allocates about 66 MiB.
    assert.is_true(allocated_kib < 8192, string.format("allocated %.0f KiB", allocated_kib))
  end)

  it("frees the reads of an unfinished frame when it closes the client, and keeps none that arrive later", function()
    local data = frame.create_frame(TEXT, string.rep(" ", 4096), true, true)
    receive(data:sub(1, 2048))
    assert.equals(2048, client.get_client_info(c).buffer_size)

    client.close_client(c, 1000, "")
    receive(data:sub(2049))

    assert.equals(0, client.get_client_info(c).buffer_size)
    assert.same({}, messages)
  end)

  it("closes with 1002 when a new text message starts inside a fragmented one", function()
    receive(frames({ TEXT, request:sub(1, 10), false }, { TEXT, request }))

    assert.same({}, messages)
    assert.equals(1002, close_code())
  end)

  it("keeps memory flat while a message arrives in many empty and one-byte fragments", function()
    local count = 20000
    receive(frames({ TEXT, "[", false }))
    collectgarbage("collect")
    local before = collectgarbage("count")
    local empty, one_byte = frame.create_frame(CONTINUATION, "", false), frame.create_frame(CONTINUATION, "1", false)
    for _ = 1, count do
      receive(empty)
      receive(one_byte)
    end
    collectgarbage("collect")
    local grown_kib = collectgarbage("count") - before
    receive(frames({ CONTINUATION, "]" }))

    assert.same({ "[" .. string.rep("1", count) .. "]" }, messages)
    -- The text itself is about 20 KiB. One table entry per fragment would hold 40000 entries, about 512 KiB.
    assert.is_true(grown_kib < 256, string.format("memory grew by %.0f KiB", grown_kib))
  end)

  it("closes with 1009 when the fragments of one message add up to more than the frame limit", function()
    local limit = frame.MAX_PAYLOAD_LENGTH
    frame.MAX_PAYLOAD_LENGTH = 16
    local ok, err = pcall(receive, frames({ TEXT, string.rep("a", 10), false }, { CONTINUATION, string.rep("a", 7) }))
    frame.MAX_PAYLOAD_LENGTH = limit
    assert(ok, err)

    assert.same({}, messages)
    assert.equals(1009, close_code())
  end)
end)
