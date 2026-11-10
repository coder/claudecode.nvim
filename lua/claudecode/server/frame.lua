---@brief WebSocket frame encoding and decoding (RFC 6455)
local utils = require("claudecode.server.utils")

local M = {}

-- WebSocket opcodes
M.OPCODE = {
  CONTINUATION = 0x0,
  TEXT = 0x1,
  BINARY = 0x2,
  CLOSE = 0x8,
  PING = 0x9,
  PONG = 0xA,
}

-- The largest payload of one frame, and of one message however many fragments it arrives in.
M.MAX_PAYLOAD_LENGTH = 100 * 1024 * 1024

---@class WebSocketFrame
---@field fin boolean Final fragment flag
---@field opcode number Frame opcode
---@field masked boolean Mask flag
---@field payload_length number Length of payload data
---@field mask string|nil 4-byte mask (if masked)
---@field payload string Frame payload data

---Parse a WebSocket frame from binary data
---
---Failure is disambiguated via the optional third return value:
---  * incomplete input ("need more bytes") returns `nil, 0` with NO third value. Once the frame's header has arrived,
---    the fourth value is the length of the whole frame.
---  * a fatal protocol violation returns `nil, 0, <close_code>, <problem>` where the close
---    code is the RFC 6455 status to send in the Close frame (1002/1007/1009)
---@param data string The binary frame data
---@param start integer|nil Byte of data where the frame starts (default 1), so a caller can parse many frames from one
---  buffer without copying the rest of it after each one
---@return WebSocketFrame|nil frame The parsed frame, or nil if incomplete/invalid
---@return number bytes_consumed Number of bytes consumed from input
---@return number|nil close_code WebSocket close code for fatal protocol violations
---@return string|integer|nil detail For a violation, what broke the protocol, short enough for one line of :messages.
---  For an incomplete frame whose header has arrived, the frame's length in bytes.
function M.parse_frame(data, start)
  if type(data) ~= "string" then
    return nil, 0
  end
  start = start or 1

  if #data < start + 1 then
    return nil, 0 -- Need at least 2 bytes for basic header
  end

  local pos = start
  local byte1 = data:byte(pos)
  local byte2 = data:byte(pos + 1)

  -- Validate byte values
  if not byte1 or not byte2 then
    return nil, 0
  end

  pos = pos + 2

  local fin = math.floor(byte1 / 128) == 1
  local rsv1 = math.floor((byte1 % 128) / 64) == 1
  local rsv2 = math.floor((byte1 % 64) / 32) == 1
  local rsv3 = math.floor((byte1 % 32) / 16) == 1
  local opcode = byte1 % 16

  local masked = math.floor(byte2 / 128) == 1
  local payload_len = byte2 % 128

  -- Validate opcode (RFC 6455 Section 5.2)
  local valid_opcodes = {
    [M.OPCODE.CONTINUATION] = true,
    [M.OPCODE.TEXT] = true,
    [M.OPCODE.BINARY] = true,
    [M.OPCODE.CLOSE] = true,
    [M.OPCODE.PING] = true,
    [M.OPCODE.PONG] = true,
  }

  if not valid_opcodes[opcode] then
    return nil, 0, 1002, string.format("Reserved opcode 0x%X", opcode)
  end

  -- Check for reserved bits (must be 0)
  if rsv1 or rsv2 or rsv3 then
    return nil, 0, 1002, "Reserved bits set"
  end

  -- Control frames must have fin=1 and payload ≤ 125 (RFC 6455 Section 5.5)
  if opcode >= M.OPCODE.CLOSE then
    if not fin then
      return nil, 0, 1002, "Fragmented control frame"
    elseif payload_len > 125 then
      return nil, 0, 1002, "Control frame over 125 bytes"
    end
  end

  -- Determine actual payload length
  local actual_payload_len = payload_len
  if payload_len == 126 then
    if #data < pos + 1 then
      return nil, 0 -- Need 2 more bytes
    end
    actual_payload_len = utils.bytes_to_uint16(data:sub(pos, pos + 1))
    pos = pos + 2

    -- Allow any valid 16-bit length for compatibility
    -- Note: Technically should be > 125, but some implementations may vary
  elseif payload_len == 127 then
    if #data < pos + 7 then
      return nil, 0 -- Need 8 more bytes
    end
    actual_payload_len = utils.bytes_to_uint64(data:sub(pos, pos + 7))
    pos = pos + 8

    -- Allow any valid 64-bit length for compatibility
    -- Note: Technically should be > 65535, but some implementations may vary

    -- Prevent extremely large payloads (DOS protection)
    if actual_payload_len > M.MAX_PAYLOAD_LENGTH then
      return nil, 0, 1009, "WebSocket frame too big"
    end
  end

  -- Additional payload length validation
  if actual_payload_len < 0 then
    return nil, 0, 1002, "Negative payload length"
  end

  -- Read mask if present
  local mask = nil
  if masked then
    if #data < pos + 3 then
      return nil, 0 -- Need 4 mask bytes
    end
    mask = data:sub(pos, pos + 3)
    pos = pos + 4
  end

  -- Check if we have enough data for payload
  if #data < pos + actual_payload_len - 1 then
    return nil, 0, nil, pos - start + actual_payload_len
  end

  -- Read payload
  local payload = data:sub(pos, pos + actual_payload_len - 1)
  pos = pos + actual_payload_len

  -- Unmask payload if needed
  if masked and mask then
    payload = utils.apply_mask(payload, mask)
  end

  -- Basic validation for close frame payload
  if opcode == M.OPCODE.CLOSE and actual_payload_len > 0 then
    if actual_payload_len == 1 then
      return nil, 0, 1002, "Close frame with a 1-byte payload"
    end
    -- Allow most close codes for compatibility, only validate UTF-8 for reason text
    if actual_payload_len > 2 then
      local reason = payload:sub(3)
      if not utils.is_valid_utf8(reason) then
        return nil, 0, 1007, "Invalid UTF-8 in close reason"
      end
    end
  end

  local frame = {
    fin = fin,
    opcode = opcode,
    masked = masked,
    payload_length = actual_payload_len,
    mask = mask,
    payload = payload,
  }

  return frame, pos - start
end

---Create a WebSocket frame
---@param opcode number Frame opcode
---@param payload string Frame payload
---@param fin boolean|nil Final fragment flag (default: true)
---@param masked boolean|nil Whether to mask the frame (default: false for server)
---@return string frame_data The encoded frame data
function M.create_frame(opcode, payload, fin, masked)
  fin = fin ~= false -- Default to true
  masked = masked == true -- Default to false

  local frame_data = {}

  -- First byte: FIN + RSV + Opcode
  local byte1 = opcode
  if fin then
    byte1 = byte1 + 128 -- Set FIN bit (0x80)
  end
  table.insert(frame_data, string.char(byte1))

  -- Payload length and mask bit
  local payload_len = #payload
  local byte2 = 0
  if masked then
    byte2 = byte2 + 128 -- Set MASK bit (0x80)
  end

  if payload_len < 126 then
    byte2 = byte2 + payload_len
    table.insert(frame_data, string.char(byte2))
  elseif payload_len < 65536 then
    byte2 = byte2 + 126
    table.insert(frame_data, string.char(byte2))
    table.insert(frame_data, utils.uint16_to_bytes(payload_len))
  else
    byte2 = byte2 + 127
    table.insert(frame_data, string.char(byte2))
    table.insert(frame_data, utils.uint64_to_bytes(payload_len))
  end

  -- Add mask if needed
  local mask = nil
  if masked then
    -- Generate random 4-byte mask
    mask = string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255))
    table.insert(frame_data, mask)
  end

  -- Add payload (masked if needed)
  if masked and mask then
    payload = utils.apply_mask(payload, mask)
  end
  table.insert(frame_data, payload)

  return table.concat(frame_data)
end

---Create a text frame
---@param text string The text to send
---@param fin boolean|nil Final fragment flag (default: true)
---@return string frame_data The encoded frame data
function M.create_text_frame(text, fin)
  return M.create_frame(M.OPCODE.TEXT, text, fin, false)
end

---Create a binary frame
---@param data string The binary data to send
---@param fin boolean|nil Final fragment flag (default: true)
---@return string frame_data The encoded frame data
function M.create_binary_frame(data, fin)
  return M.create_frame(M.OPCODE.BINARY, data, fin, false)
end

---Create a close frame
---@param code number|nil Close code (default: 1000)
---@param reason string|nil Close reason (default: empty)
---@return string frame_data The encoded frame data
function M.create_close_frame(code, reason)
  code = code or 1000
  reason = reason or ""

  local payload = utils.uint16_to_bytes(code) .. reason
  return M.create_frame(M.OPCODE.CLOSE, payload, true, false)
end

---Create a ping frame
---@param data string|nil Ping data (default: empty)
---@return string frame_data The encoded frame data
function M.create_ping_frame(data)
  data = data or ""
  return M.create_frame(M.OPCODE.PING, data, true, false)
end

---Create a pong frame
---@param data string|nil Pong data (should match ping data)
---@return string frame_data The encoded frame data
function M.create_pong_frame(data)
  data = data or ""
  return M.create_frame(M.OPCODE.PONG, data, true, false)
end

---Check if an opcode is a control frame
---@param opcode number The opcode to check
---@return boolean is_control True if it's a control frame
function M.is_control_frame(opcode)
  return opcode >= 0x8
end

return M
