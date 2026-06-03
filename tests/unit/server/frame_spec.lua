require("tests.busted_setup")

local client = require("claudecode.server.client")
local frame = require("claudecode.server.frame")
local utils = require("claudecode.server.utils")

describe("WebSocket frame parsing", function()
  describe("parse_frame fatal protocol violations", function()
    it("returns close code 1002 for an invalid opcode", function()
      -- byte1: fin=1, opcode=0x3 (reserved, invalid); byte2: unmasked, len=0
      local data = string.char(0x83, 0x00)
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.equals(1002, close_code)
    end)

    it("returns close code 1002 when reserved bits are set", function()
      -- byte1: fin=1, rsv1=1 (0x40), opcode=TEXT(0x1) => 0xC1; byte2: len=0
      local data = string.char(0xC1, 0x00)
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.equals(1002, close_code)
    end)

    it("returns close code 1002 for an oversized control frame", function()
      -- byte1: fin=1, opcode=PING(0x9) => 0x89; byte2: unmasked, len=126 (>125)
      local data = string.char(0x89, 0x7E)
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.equals(1002, close_code)
    end)

    it("returns close code 1002 for a fragmented control frame (fin=0)", function()
      -- byte1: fin=0, opcode=CLOSE(0x8) => 0x08; byte2: unmasked, len=0
      local data = string.char(0x08, 0x00)
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.equals(1002, close_code)
    end)

    it("returns close code 1002 for a 1-byte close frame payload", function()
      -- byte1: fin=1, opcode=CLOSE(0x8) => 0x88; byte2: unmasked, len=1; 1 payload byte
      local data = string.char(0x88, 0x01) .. string.char(0x03)
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.equals(1002, close_code)
    end)

    it("returns close code 1009 for a declared payload over the 100MB cap", function()
      -- byte1: fin=1, opcode=BINARY(0x2) => 0x82; byte2: unmasked, len=127 (64-bit length)
      -- 64-bit length = 200MB, which exceeds the 100MB cap.
      local big_len = 200 * 1024 * 1024
      local data = string.char(0x82, 0x7F) .. utils.uint64_to_bytes(big_len)
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.equals(1009, close_code)
    end)

    it("returns close code 1007 for invalid UTF-8 in a text frame", function()
      -- byte1: fin=1, opcode=TEXT(0x1) => 0x81; byte2: unmasked, len=2
      -- payload: 0xFF 0xFE is not valid UTF-8.
      local data = string.char(0x81, 0x02) .. string.char(0xFF, 0xFE)
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.equals(1007, close_code)
    end)

    it("returns close code 1007 for invalid UTF-8 in a close reason", function()
      -- byte1: fin=1, opcode=CLOSE(0x8) => 0x88; byte2: unmasked, len=4
      -- payload: 2-byte close code (1000) + 2 invalid UTF-8 reason bytes.
      local payload = utils.uint16_to_bytes(1000) .. string.char(0xFF, 0xFE)
      local data = string.char(0x88, 0x04) .. payload
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.equals(1007, close_code)
    end)
  end)

  describe("parse_frame incomplete frames", function()
    it("returns nil, 0 with NO third value when the payload is truncated", function()
      -- Header declares a 10-byte unmasked text payload but only 3 bytes follow.
      -- byte1: fin=1, opcode=TEXT(0x1) => 0x81; byte2: unmasked, len=10
      local data = string.char(0x81, 0x0A) .. "abc"
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.is_nil(close_code)
    end)

    it("returns nil, 0 with NO third value when only one header byte is present", function()
      local parsed, consumed, close_code = frame.parse_frame(string.char(0x81))

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.is_nil(close_code)
    end)

    it("returns nil, 0 with NO third value when extended length bytes are missing", function()
      -- byte2 = 126 means a 16-bit extended length follows, but it is absent.
      local data = string.char(0x81, 0x7E)
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.is_nil(close_code)
    end)

    it("returns nil, 0 with NO third value when mask bytes are missing", function()
      -- Masked frame (0x80) declaring a 4-byte payload, but the 4 mask bytes are absent.
      local data = string.char(0x81, 0x84)
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_nil(parsed)
      assert.equals(0, consumed)
      assert.is_nil(close_code)
    end)
  end)

  describe("parse_frame valid frames remain unaffected", function()
    it("parses a valid unmasked text frame without a close code", function()
      local data = frame.create_text_frame("hello")
      local parsed, consumed, close_code = frame.parse_frame(data)

      assert.is_table(parsed)
      assert.equals(frame.OPCODE.TEXT, parsed.opcode)
      assert.equals("hello", parsed.payload)
      assert.equals(#data, consumed)
      assert.is_nil(close_code)
    end)
  end)
end)

describe("WebSocket client malformed frame handling", function()
  -- Build a client whose tcp_handle records writes so we can assert that a
  -- Close frame was sent and the connection torn down.
  local function make_client()
    local writes = {}
    local handle = {
      _closed = false,
      write = function(_, data, callback)
        table.insert(writes, data)
        if callback then
          callback()
        end
        return true
      end,
      close = function(self)
        self._closed = true
        return true
      end,
      is_closing = function(self)
        return self._closed
      end,
    }

    local c = {
      id = "test_client",
      tcp_handle = handle,
      state = "connected",
      buffer = "",
      handshake_complete = true,
      last_ping = 0,
      last_pong = 0,
    }

    return c, writes, handle
  end

  local function noop() end

  it("closes the connection and drains the buffer on a malformed frame", function()
    local c, writes = make_client()

    local on_error = spy.new(noop)
    local on_close = spy.new(noop)

    -- A text frame whose payload is invalid UTF-8 is a fatal (1007) violation.
    local malformed = string.char(0x81, 0x02) .. string.char(0xFF, 0xFE)

    client.process_data(c, malformed, noop, on_close, on_error)

    -- Connection must be torn down rather than left wedged.
    assert.is_true(c.state == "closing" or c.state == "closed")

    -- A Close frame must have been written.
    assert.is_true(#writes >= 1)
    local last_frame = frame.parse_frame(writes[#writes])
    assert.is_table(last_frame)
    assert.equals(frame.OPCODE.CLOSE, last_frame.opcode)

    -- The error callback must have fired for the protocol violation.
    assert.spy(on_error).was_called()

    -- Regression: the malformed bytes must NOT remain buffered for re-parsing.
    assert.is_false(c.buffer:find(string.char(0xFF, 0xFE), 1, true) ~= nil)
  end)

  it("sends a Close frame carrying the 1002 status for an invalid opcode", function()
    local c, writes = make_client()

    -- Invalid opcode 0x3 => fatal 1002 protocol error.
    local malformed = string.char(0x83, 0x00)

    client.process_data(c, malformed, noop, noop, noop)

    assert.is_true(#writes >= 1)
    local close_frame = frame.parse_frame(writes[#writes])
    assert.is_table(close_frame)
    assert.equals(frame.OPCODE.CLOSE, close_frame.opcode)
    -- Close payload begins with the 2-byte big-endian status code.
    assert.is_true(#close_frame.payload >= 2)
    local code = close_frame.payload:byte(1) * 256 + close_frame.payload:byte(2)
    assert.equals(1002, code)
  end)

  it("keeps an incomplete frame buffered and the connection open", function()
    local c, writes = make_client()

    local on_error = spy.new(noop)

    -- Header declares a 10-byte text payload but only 3 bytes are present.
    local incomplete = string.char(0x81, 0x0A) .. "abc"

    client.process_data(c, incomplete, noop, noop, on_error)

    -- Connection stays open; nothing written; no error raised.
    assert.equals("connected", c.state)
    assert.equals(0, #writes)
    assert.spy(on_error).was_not_called()

    -- The bytes remain buffered, waiting for the rest of the frame.
    assert.equals(incomplete, c.buffer)
  end)
end)
