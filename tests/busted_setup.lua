-- Test setup for busted

-- Create mock vim API if we're running tests outside of Neovim
if not _G.vim then
  _G.vim = require("tests.mocks.vim")
end

-- Ensure vim global is accessible
_G.vim = _G.vim or {}

-- Setup test globals
_G.assert = require("luassert")

-- Helper function to verify expectations
_G.expect = function(value)
  return {
    to_be = function(expected)
      assert.are.equal(expected, value)
    end,
    to_be_nil = function()
      assert.is_nil(value)
    end,
    to_be_true = function()
      assert.is_true(value)
    end,
    to_be_false = function()
      assert.is_false(value)
    end,
    to_be_table = function()
      assert.is_table(value)
    end,
    to_be_string = function()
      assert.is_string(value)
    end,
    to_be_function = function()
      assert.is_function(value)
    end,
    to_be_boolean = function()
      assert.is_boolean(value)
    end,
    to_be_at_least = function(expected)
      assert.is_true(value >= expected)
    end,
    to_have_key = function(key)
      assert.is_table(value)
      assert.not_nil(value[key])
    end,
    -- to_contain was here, moved to _G.assert_contains
    not_to_be_nil = function()
      assert.is_not_nil(value)
    end,
    -- not_to_contain was here, moved to _G.assert_not_contains
    to_be_truthy = function()
      assert.is_truthy(value)
    end,
    to_match = function(pattern)
      assert.is_string(value)
      assert.is_true(
        string.find(value, pattern, 1, true) ~= nil,
        "Expected string '" .. value .. "' to match pattern '" .. pattern .. "'"
      )
    end,
  }
end

_G.assert_contains = function(actual_value, expected_pattern)
  if type(actual_value) == "string" then
    if type(expected_pattern) ~= "string" then
      error(
        "assert_contains expected a string pattern for a string actual_value, but expected_pattern was type: "
          .. type(expected_pattern)
      )
    end
    assert.is_true(
      string.find(actual_value, expected_pattern, 1, true) ~= nil,
      "Expected string '" .. actual_value .. "' to contain '" .. expected_pattern .. "'"
    )
  elseif type(actual_value) == "table" then
    local found = false
    for _, v in ipairs(actual_value) do
      if v == expected_pattern then
        found = true
        break
      end
    end
    assert.is_true(found, "Expected table to contain value: " .. tostring(expected_pattern))
  else
    error("assert_contains can only be used with string or table actual_values, got type: " .. type(actual_value))
  end
end

_G.assert_not_contains = function(actual_value, expected_pattern)
  if type(actual_value) == "string" then
    if type(expected_pattern) ~= "string" then
      error(
        "assert_not_contains expected a string pattern for a string actual_value, but expected_pattern was type: "
          .. type(expected_pattern)
      )
    end
    assert.is_true(
      string.find(actual_value, expected_pattern, 1, true) == nil,
      "Expected string '" .. actual_value .. "' NOT to contain '" .. expected_pattern .. "'"
    )
  elseif type(actual_value) == "table" then
    local found = false
    for _, v in ipairs(actual_value) do
      if v == expected_pattern then
        found = true
        break
      end
    end
    assert.is_false(found, "Expected table NOT to contain value: " .. tostring(expected_pattern))
  else
    error("assert_not_contains can only be used with string or table actual_values, got type: " .. type(actual_value))
  end
end

-- JSON encoding/decoding helpers for tests
_G.json_encode = function(data)
  if type(data) == "table" then
    local parts = {}
    local is_array = true

    -- Check if it's an array (all numeric, positive keys) or an object
    for k, _ in pairs(data) do
      if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
        is_array = false
        break
      end
    end

    if is_array then
      table.insert(parts, "[")
      for i, v in ipairs(data) do
        if i > 1 then
          table.insert(parts, ",")
        end
        table.insert(parts, _G.json_encode(v))
      end
      table.insert(parts, "]")
    else
      table.insert(parts, "{")
      local first = true
      for k, v in pairs(data) do
        if not first then
          table.insert(parts, ",")
        end
        first = false
        -- Handle special Lua keywords as object keys
        local key_str = tostring(k)
        if key_str == "end" then
          table.insert(parts, '["end"]:')
        else
          table.insert(parts, '"' .. key_str .. '":')
        end
        table.insert(parts, _G.json_encode(v))
      end
      table.insert(parts, "}")
    end

    return table.concat(parts)
  elseif type(data) == "string" then
    -- Handle escape sequences properly
    local escaped = data
      :gsub("\\", "\\\\") -- Escape backslashes first
      :gsub('"', '\\"') -- Escape quotes
      :gsub("\n", "\\n") -- Escape newlines
      :gsub("\r", "\\r") -- Escape carriage returns
      :gsub("\t", "\\t") -- Escape tabs
    return '"' .. escaped .. '"'
  elseif type(data) == "boolean" then
    return data and "true" or "false"
  elseif type(data) == "number" then
    return tostring(data)
  else
    return "null"
  end
end

-- Simple JSON decoder for test purposes
_G.json_decode = function(str)
  if not str or str == "" then
    return nil
  end

  local pos = 1

  local function skip_whitespace()
    while pos <= #str and str:sub(pos, pos):match("%s") do
      pos = pos + 1
    end
  end

  local function parse_value()
    skip_whitespace()
    if pos > #str then
      return nil
    end

    local char = str:sub(pos, pos)

    if char == '"' then
      -- Parse string
      pos = pos + 1
      local start = pos
      while pos <= #str and str:sub(pos, pos) ~= '"' do
        if str:sub(pos, pos) == "\\" then
          pos = pos + 1
        end
        pos = pos + 1
      end
      local value = str
        :sub(start, pos - 1)
        :gsub('\\"', '"') -- Unescape quotes
        :gsub("\\\\", "\\") -- Unescape backslashes
        :gsub("\\n", "\n") -- Unescape newlines
        :gsub("\\r", "\r") -- Unescape carriage returns
        :gsub("\\t", "\t") -- Unescape tabs
      pos = pos + 1
      return value
    elseif char == "{" then
      -- Parse object
      pos = pos + 1
      local obj = {}
      skip_whitespace()

      if pos <= #str and str:sub(pos, pos) == "}" then
        pos = pos + 1
        return obj
      end

      while true do
        skip_whitespace()

        -- Parse key
        if str:sub(pos, pos) ~= '"' and str:sub(pos, pos) ~= "[" then
          break
        end

        local key
        if str:sub(pos, pos) == '"' then
          key = parse_value()
        elseif str:sub(pos, pos) == "[" then
          -- Handle bracket notation like ["end"]
          pos = pos + 2 -- skip ["
          local start = pos
          while pos <= #str and str:sub(pos, pos) ~= '"' do
            pos = pos + 1
          end
          key = str:sub(start, pos - 1)
          pos = pos + 2 -- skip "]
        else
          break
        end

        skip_whitespace()
        if pos > #str or str:sub(pos, pos) ~= ":" then
          break
        end
        pos = pos + 1

        -- Parse value
        local value = parse_value()
        obj[key] = value

        skip_whitespace()
        if pos > #str then
          break
        end

        if str:sub(pos, pos) == "}" then
          pos = pos + 1
          break
        elseif str:sub(pos, pos) == "," then
          pos = pos + 1
        else
          break
        end
      end

      return obj
    elseif char == "[" then
      -- Parse array
      pos = pos + 1
      local arr = {}
      skip_whitespace()

      if pos <= #str and str:sub(pos, pos) == "]" then
        pos = pos + 1
        return arr
      end

      while true do
        table.insert(arr, parse_value())
        skip_whitespace()

        if pos > #str then
          break
        end

        if str:sub(pos, pos) == "]" then
          pos = pos + 1
          break
        elseif str:sub(pos, pos) == "," then
          pos = pos + 1
        else
          break
        end
      end

      return arr
    elseif char:match("%d") or char == "-" then
      -- Parse number
      local start = pos
      if char == "-" then
        pos = pos + 1
      end
      while pos <= #str and str:sub(pos, pos):match("%d") do
        pos = pos + 1
      end
      if pos <= #str and str:sub(pos, pos) == "." then
        pos = pos + 1
        while pos <= #str and str:sub(pos, pos):match("%d") do
          pos = pos + 1
        end
      end
      return tonumber(str:sub(start, pos - 1))
    elseif str:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif str:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif str:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    else
      return nil
    end
  end

  return parse_value()
end

-- Return true to indicate setup was successful
return {
  json_encode = _G.json_encode,
  json_decode = _G.json_decode,
}
