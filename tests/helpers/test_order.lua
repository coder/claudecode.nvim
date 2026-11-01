--- Busted helper, loaded through `.busted`: a spec must not register tests inside a `pairs()` loop. LuaJIT seeds its
--- string hash in each process, so `pairs()` visits string keys in a different order in each run, and the seed that
--- `mise run test` prints would not repeat the test order. Loop over an array with `ipairs` instead.

-- The chunk names of the spec files: "@" and the path busted passed to loadfile, relative or absolute. Only code in
-- them counts. Busted's own event loop iterates its channels with pairs().
local spec_sources = {}

-- A coroutine's stack ends where it was resumed. Each resume records the loop running in the code that resumed it.
local loop_at_resume = setmetatable({}, { __mode = "k" })

---Finds a `pairs()` loop that runs in a spec file further up the stack, or in the code that resumed this coroutine. A
---generic `for` keeps its iterator in the hidden local "(for generator)", and `pairs()` returns `next` as that iterator.
---@param level integer The stack level to start at
---@return string|nil where "file:line" of the loop's current line
local function pairs_loop_above(level)
  while true do
    local info = debug.getinfo(level + 1, "Sl")
    if not info then
      local current = coroutine.running()
      return current and loop_at_resume[current]
    end
    if spec_sources[info.source] then
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

local resume, wrap = coroutine.resume, coroutine.wrap

function coroutine.resume(co, ...) -- luacheck: ignore 122
  if type(co) == "thread" then
    loop_at_resume[co] = pairs_loop_above(2)
  end
  return resume(co, ...)
end

function coroutine.wrap(fn) -- luacheck: ignore 122
  local co, first_loop
  -- The native wrap keeps its own error handling. The trampoline learns the coroutine on its first run.
  local resume_wrapped = wrap(function(...)
    co = coroutine.running()
    loop_at_resume[co] = first_loop
    return fn(...)
  end)
  return function(...)
    local loop = pairs_loop_above(2)
    if co then
      loop_at_resume[co] = loop
    else
      first_loop = loop
    end
    return resume_wrapped(...)
  end
end

return function(busted)
  -- Priority 1 runs each subscriber before busted's own, which stops the event. Returning true as the second value
  -- passes the event on to it.
  busted.subscribe({ "register", "file" }, function(name)
    spec_sources["@" .. name] = true
    return nil, true
  end, { priority = 1 })

  local reported = {}
  for _, descriptor in ipairs({ "describe", "it", "pending" }) do
    busted.subscribe({ "register", descriptor }, function(name)
      local loop = pairs_loop_above(2)
      if loop and not reported[loop] then
        reported[loop] = true
        -- An error event fails the run without raising, so the rest of the block still registers and runs.
        local context = busted.context.get()
        local message =
          string.format("%s registers %q inside a pairs() loop; loop over an array with ipairs", loop, name)
        busted.publish({ "error", context.descriptor }, context, busted.context.parent(context), message, {})
      end
      return nil, true
    end, { priority = 1 })
  end
  return true
end
