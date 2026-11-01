--- Busted helper, loaded through `.busted`: a spec must not register tests inside a `pairs()` loop. LuaJIT seeds its
--- string hash in each process, so `pairs()` visits string keys in a different order in each run, and the seed that
--- `mise run test` prints would not repeat the test order. Loop over an array with `ipairs` instead.

---Finds a `pairs()` loop that is running in a test file further up the stack. A generic `for` keeps its iterator in
---the hidden local "(for generator)", and `pairs()` returns `next` as that iterator.
---@param level integer The stack level to start at
---@return string|nil where "file:line" of the loop's current line
local function pairs_loop_above(level)
  while true do
    local info = debug.getinfo(level + 1, "Sl")
    if not info then
      return nil
    end
    -- Only test code: busted's own event loop iterates its channels with pairs().
    if info.source:match("^@.*tests/") then
      local index = 1
      while true do
        local name, value = debug.getlocal(level + 1, index)
        if not name then
          break
        end
        if name == "(for generator)" and value == next then
          return info.short_src .. ":" .. info.currentline
        end
        index = index + 1
      end
    end
    level = level + 1
  end
end

return function(busted)
  for _, descriptor in ipairs({ "describe", "it", "pending" }) do
    -- Priority 1 runs this before busted's own subscriber, which stops the event. Returning true as the second
    -- value passes the event on to it.
    busted.subscribe({ "register", descriptor }, function(name)
      local loop = pairs_loop_above(2)
      if loop then
        error(string.format("%s registers %q inside a pairs() loop; loop over an array with ipairs", loop, name), 0)
      end
      return nil, true
    end, { priority = 1 })
  end
  return true
end
