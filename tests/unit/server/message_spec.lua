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
  local function close_code()
    for _, w in ipairs(writes) do
      local parsed = frame.parse_frame(w.data)
      if parsed and parsed.opcode == frame.OPCODE.CLOSE then
        assert.is_false(w.closing, "the Close frame was written after the socket closed")
        return parsed.payload:byte(1) * 256 + parsed.payload:byte(2)
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
