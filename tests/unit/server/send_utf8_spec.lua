--- Every message the server sends goes out as a WebSocket text frame. The client drops the connection when a
--- text frame is not valid UTF-8, and a buffer name or file path can hold any bytes (issue #374).
require("tests.busted_setup")
local client_manager = require("claudecode.server.client")
local frame = require("claudecode.server.frame")

describe("WebSocket client send_message", function()
  local replacement = "\239\191\189" -- U+FFFD REPLACEMENT CHARACTER

  -- Returns the payload of the one text frame that send_message writes for message.
  local function sent_payload(message)
    local written = {}
    local client = {
      state = "connected",
      tcp_handle = {
        write = function(_, data)
          table.insert(written, data)
        end,
      },
    }
    client_manager.send_message(client, message)
    assert.are.equal(1, #written)
    local parsed = frame.parse_frame(written[1])
    assert.is_not_nil(parsed, "the frame is not valid UTF-8, so the client drops the connection")
    return parsed.payload
  end

  it("replaces an invalid byte in a file path with U+FFFD", function()
    -- A Latin-1 file name: é is the single byte 0xE9.
    local payload = sent_payload('{"params":{"filePath":"/work/caf\233.txt"}}')
    assert.are.equal('{"params":{"filePath":"/work/caf' .. replacement .. '.txt"}}', payload)
  end)

  it("keeps the JSON intact when an invalid sequence ends right before a closing quote", function()
    -- The first two bytes of €, cut off by the end of the string.
    assert.are.equal('{"a":"x' .. replacement .. '"}', sent_payload('{"a":"x\226\130"}'))
  end)

  it("sends valid UTF-8 unchanged", function()
    local message = '{"a":"naïve 日本 😀"}'
    assert.are.equal(message, sent_payload(message))
  end)
end)
