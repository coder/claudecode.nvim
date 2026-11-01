--- Busted helper, loaded through `.busted`: a spec must not register tests inside a `pairs()` loop. LuaJIT seeds its
--- string hash in each process, so `pairs()` visits string keys in a different order in each run, and the seed that
--- `mise run test` prints would not repeat the test order. Loop over an array with `ipairs` instead.

-- The chunk names of the spec files: "@" and the path busted passed to loadfile, relative or absolute. Only code in
-- them, and in files under the tests directory that holds this helper, counts. Busted's own event loop iterates its
-- channels with pairs().
local spec_sources = {}

local abspath = require("pl.path").abspath
local tests_dir = abspath(debug.getinfo(1, "S").source:sub(2)):match("^(.*/)helpers/[^/]+$")
assert(tests_dir, "test_order.lua must be in the helpers directory of the tests")
local counts = setmetatable({}, {
  __index = function(cache, source)
    local found = source:sub(1, 1) == "@" and abspath(source:sub(2)):sub(1, #tests_dir) == tests_dir
    cache[source] = found
    return found
  end,
})

-- A coroutine's stack ends where it was resumed. Each resume records the loop running in the code that resumed it.
local loop_at_resume = setmetatable({}, { __mode = "k" })

---Finds a `pairs()` loop that runs in a spec file further up the stack, or in the code that resumed this coroutine. A
---generic `for` keeps its iterator in the hidden local "(for generator)", and `pairs()` returns `next` as that iterator.
---@param level integer The stack level to start at
---@return string|nil where "path:line" of the loop's current line, with the full path: short_src cuts a long one
local function pairs_loop_above(level)
  while true do
    local info = debug.getinfo(level + 1, "Sl")
    if not info then
      local current = coroutine.running()
      return current and loop_at_resume[current]
    end
    if spec_sources[info.source] or counts[info.source] then
      local index = 1
      while true do
        local name, value = debug.getlocal(level + 1, index)
        if not name then
          break
        end
        if name == "(for generator)" and value == next then
          return info.source:sub(2) .. ":" .. info.currentline
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
  local registering = false
  for _, descriptor in ipairs({ "describe", "it", "pending" }) do
    busted.subscribe({ "register", descriptor }, function(name, fn, trace, attributes)
      local loop = not registering and pairs_loop_above(2)
      if not loop or reported[loop] then
        return nil, true
      end
      reported[loop] = true
      -- "path:line: " first, as in a Lua error, so busted adds no location of its own to the failure message.
      local message =
        string.format("%s: registers %q inside a pairs() loop; loop over an array with ipairs", loop, name)
      if descriptor == "it" then
        -- Register the test once more, to fail after its body runs, and stop this event, so every output marks this
        -- test as failed.
        registering = true
        busted.publish({ "register", descriptor }, name, function(...)
          fn(...)
          error(message, 0)
        end, trace, attributes)
        registering = false
        return nil, false
      end
      -- A failing block would not run its tests. An error event fails the run without raising, so the rest of the
      -- block still registers and runs.
      local context = busted.context.get()
      busted.publish({ "error", context.descriptor }, context, busted.context.parent(context), message, {})
      return nil, true
    end, { priority = 1 })
  end
  return true
end
