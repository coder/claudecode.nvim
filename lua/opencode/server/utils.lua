---@brief Utility functions for WebSocket server implementation
local M = {}

-- Lua 5.1 compatible bitwise operations (arithmetic emulation).
local function band(a, b)
  local result = 0
  local bitval = 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then
      result = result + bitval
    end
    bitval = bitval * 2
    a = math.floor(a / 2)
    b = math.floor(b / 2)
  end
  return result
end

local function bor(a, b)
  local result = 0
  local bitval = 1
  while a > 0 or b > 0 do
    if a % 2 == 1 or b % 2 == 1 then
      result = result + bitval
    end
    bitval = bitval * 2
    a = math.floor(a / 2)
    b = math.floor(b / 2)
  end
  return result
end

local function bxor(a, b)
  local result = 0
  local bitval = 1
  while a > 0 or b > 0 do
    if (a % 2) ~= (b % 2) then
      result = result + bitval
    end
    bitval = bitval * 2
    a = math.floor(a / 2)
    b = math.floor(b / 2)
  end
  return result
end

local function bnot(a)
  return bxor(a, 0xFFFFFFFF)
end

local function lshift(value, amount)
  local shifted_val = value * (2 ^ amount)
  return shifted_val % (2 ^ 32)
end

local function rshift(value, amount)
  return math.floor(value / (2 ^ amount))
end

local function rotleft(value, amount)
  local mask = 0xFFFFFFFF
  value = band(value, mask)
  local part1 = lshift(value, amount)
  local part2 = rshift(value, 32 - amount)
  return band(bor(part1, part2), mask)
end

local function add32(a, b)
  local sum = a + b
  return band(sum, 0xFFFFFFFF)
end

---Generate a random, spec-compliant WebSocket key.
---@return string key Base64 encoded 16-byte random nonce.
function M.generate_websocket_key()
  local random_bytes = {}
  for _ = 1, 16 do
    random_bytes[#random_bytes + 1] = string.char(math.random(0, 255))
  end
  return M.base64_encode(table.concat(random_bytes))
end

---Base64 encode a string
---@param data string The data to encode
---@return string encoded The base64 encoded string
function M.base64_encode(data)
  local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local result = {}
  local padding = ""

  local pad_len = 3 - (#data % 3)
  if pad_len ~= 3 then
    data = data .. string.rep("\0", pad_len)
    padding = string.rep("=", pad_len)
  end

  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local bitmap = a * 65536 + b * 256 + c

    -- Use table for efficient string building
    result[#result + 1] = chars:sub(math.floor(bitmap / 262144) + 1, math.floor(bitmap / 262144) + 1)
    result[#result + 1] = chars:sub(math.floor((bitmap % 262144) / 4096) + 1, math.floor((bitmap % 262144) / 4096) + 1)
    result[#result + 1] = chars:sub(math.floor((bitmap % 4096) / 64) + 1, math.floor((bitmap % 4096) / 64) + 1)
    result[#result + 1] = chars:sub((bitmap % 64) + 1, (bitmap % 64) + 1)
  end

  local encoded = table.concat(result)
  return encoded:sub(1, #encoded - #padding) .. padding
end

---Base64 decode a string
---@param data string The base64 encoded string
---@return string|nil decoded The decoded string, or nil on error (e.g. invalid char)
function M.base64_decode(data)
  local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local lookup = {}
  for i = 1, #chars do
    lookup[chars:sub(i, i)] = i - 1
  end
  lookup["="] = 0

  local result = {}
  local buffer = 0
  local bits = 0

  for i = 1, #data do
    local char = data:sub(i, i)
    local value = lookup[char]

    if value == nil then
      return nil
    end

    if char == "=" then
      break
    end

    buffer = (buffer * 64) + value
    bits = bits + 6

    if bits >= 8 then
      bits = bits - 8
      result[#result + 1] = string.char(rshift(buffer, bits))
      buffer = band(buffer, (lshift(1, bits)) - 1)
    end
  end
  return table.concat(result)
end

---Pure Lua SHA-1 implementation
---@param data string The data to hash
---@return string|nil hash The SHA-1 hash in binary format, or nil on error
function M.sha1(data)
  if type(data) ~= "string" then
    return nil
  end

  -- Validate input data is reasonable size (DOS protection)
  if #data > 10 * 1024 * 1024 then -- 10MB limit
    return nil
  end

  local h0 = 0x67452301
  local h1 = 0xEFCDAB89
  local h2 = 0x98BADCFE
  local h3 = 0x10325476
  local h4 = 0xC3D2E1F0

  local msg = data
  local msg_len = #msg
  local bit_len = msg_len * 8

  msg = msg .. string.char(0x80)

  -- Append 0 <= k < 512 bits '0', where the resulting message length
  -- (in bits) is congruent to 448 (mod 512)
  while (#msg % 64) ~= 56 do
    msg = msg .. string.char(0x00)
  end

  -- Append length as 64-bit big-endian integer
  for i = 7, 0, -1 do
    msg = msg .. string.char(band(rshift(bit_len, i * 8), 0xFF))
  end

  for chunk_start = 1, #msg, 64 do
    local w = {}

    -- Break chunk into sixteen 32-bit big-endian words
    for i = 0, 15 do
      local offset = chunk_start + i * 4
      w[i] = bor(
        bor(bor(lshift(msg:byte(offset), 24), lshift(msg:byte(offset + 1), 16)), lshift(msg:byte(offset + 2), 8)),
        msg:byte(offset + 3)
      )
    end

    -- Extend the sixteen 32-bit words into eighty 32-bit words
    for i = 16, 79 do
      w[i] = rotleft(bxor(bxor(bxor(w[i - 3], w[i - 8]), w[i - 14]), w[i - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4

    for i = 0, 79 do
      local f, k
      if i <= 19 then
        f = bor(band(b, c), band(bnot(b), d))
        k = 0x5A827999
      elseif i <= 39 then
        f = bxor(bxor(b, c), d)
        k = 0x6ED9EBA1
      elseif i <= 59 then
        f = bor(bor(band(b, c), band(b, d)), band(c, d))
        k = 0x8F1BBCDC
      else
        f = bxor(bxor(b, c), d)
        k = 0xCA62C1D6
      end

      local temp = add32(add32(add32(add32(rotleft(a, 5), f), e), k), w[i])
      e = d
      d = c
      c = rotleft(b, 30)
      b = a
      a = temp
    end

    h0 = add32(h0, a)
    h1 = add32(h1, b)
    h2 = add32(h2, c)
    h3 = add32(h3, d)
    h4 = add32(h4, e)
  end

  -- Produce the final hash value as a 160-bit (20-byte) binary string
  local result = ""
  for _, h in ipairs({ h0, h1, h2, h3, h4 }) do
    result = result
      .. string.char(band(rshift(h, 24), 0xFF), band(rshift(h, 16), 0xFF), band(rshift(h, 8), 0xFF), band(h, 0xFF))
  end

  return result
end

---Generate WebSocket accept key from client key
---@param client_key string The client's WebSocket-Key header value
---@return string|nil accept_key The WebSocket accept key, or nil on error
function M.generate_accept_key(client_key)
  local magic_string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  -- As per RFC 6455, the server concatenates the Sec-WebSocket-Key header value
  -- with a magic string, SHA1s the result, and then Base64 encodes it.
  local combined = client_key .. magic_string
  local hash = M.sha1(combined)
  if not hash then
    return nil
  end

  return M.base64_encode(hash)
end

---Parse HTTP headers from request string
---@param request string The HTTP request string
---@return table headers Table of header name -> value pairs
function M.parse_http_headers(request)
  local headers = {}
  local lines = {}

  for line in request:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  for i = 2, #lines do
    local line = lines[i]
    local name, value = line:match("^([^:]+):%s*(.+)$")
    if name and value then
      headers[name:lower()] = value
    end
  end

  return headers
end

---Check if a string contains valid UTF-8
---@param str string The string to check
---@return boolean valid True if the string is valid UTF-8
function M.is_valid_utf8(str)
  local i = 1
  while i <= #str do
    local byte = str:byte(i)
    local char_len = 1

    if byte >= 0x80 then
      if byte >= 0xF0 then
        char_len = 4
      elseif byte >= 0xE0 then
        char_len = 3
      elseif byte >= 0xC0 then
        char_len = 2
      else
        return false
      end

      for j = 1, char_len - 1 do
        if i + j > #str then
          return false
        end
        local cont_byte = str:byte(i + j)
        if cont_byte < 0x80 or cont_byte >= 0xC0 then
          return false
        end
      end
    end

    i = i + char_len
  end

  return true
end

---Convert a 16-bit number to big-endian bytes
---@param num number The number to convert
---@return string bytes The big-endian byte representation
function M.uint16_to_bytes(num)
  return string.char(math.floor(num / 256), num % 256)
end

---Convert a 64-bit number to big-endian bytes
---@param num number The number to convert
---@return string bytes The big-endian byte representation
function M.uint64_to_bytes(num)
  local bytes = {}
  for i = 8, 1, -1 do
    bytes[i] = num % 256
    num = math.floor(num / 256)
  end
  return string.char(unpack(bytes))
end

---Convert big-endian bytes to a 16-bit number
---@param bytes string The byte string (2 bytes)
---@return number num The converted number
function M.bytes_to_uint16(bytes)
  if #bytes < 2 then
    return 0
  end
  return bytes:byte(1) * 256 + bytes:byte(2)
end

---Convert big-endian bytes to a 64-bit number
---@param bytes string The byte string (8 bytes)
---@return number num The converted number
function M.bytes_to_uint64(bytes)
  if #bytes < 8 then
    return 0
  end

  local num = 0
  for i = 1, 8 do
    num = num * 256 + bytes:byte(i)
  end
  return num
end

---XOR lookup table for faster operations
local xor_table = {}
for i = 0, 255 do
  xor_table[i] = {}
  for j = 0, 255 do
    local result = 0
    local a, b = i, j
    local bit_val = 1

    while a > 0 or b > 0 do
      local a_bit = a % 2
      local b_bit = b % 2

      if a_bit ~= b_bit then
        result = result + bit_val
      end

      a = math.floor(a / 2)
      b = math.floor(b / 2)
      bit_val = bit_val * 2
    end

    xor_table[i][j] = result
  end
end

---Apply XOR mask to payload data
---@param data string The data to mask/unmask
---@param mask string The 4-byte mask
---@return string masked The masked/unmasked data
function M.apply_mask(data, mask)
  local result = {}
  local mask_bytes = { mask:byte(1, 4) }

  for i = 1, #data do
    local mask_idx = ((i - 1) % 4) + 1
    local data_byte = data:byte(i)
    result[i] = string.char(xor_table[data_byte][mask_bytes[mask_idx]])
  end

  return table.concat(result)
end

---Shuffle an array in place using Fisher-Yates algorithm
---@param tbl table The array to shuffle
function M.shuffle_array(tbl)
  math.randomseed(os.time())
  for i = #tbl, 2, -1 do
    local j = math.random(i)
    tbl[i], tbl[j] = tbl[j], tbl[i]
  end
end

return M
