-- Scenario: the keepalive check runs after a poll that Claude's answer did not reach. Claude runs in a process of its
-- own and answers every ping. Interval 200 ms. Three runs, each with a fresh plugin and a fresh Claude:
--   big-message:  the loop blocks for 2.7 intervals in an idle callback right after a tick. Claude writes a 300 KB text
--                 frame and then its pong during the block, so the pong waits behind more unread data than the socket
--                 holds, and the one poll after the block does not reach it.
--   two-blocks:   a block of 1.4 intervals in a check callback right after a ping, then, after the late tick, a block
--                 of 1.4 intervals in an idle callback before the poll. Each block is below the gap of 1.5 intervals,
--                 and the oldest ping is 2.8 intervals old at the check. Claude writes 300 KB and then its pong.
--   sleep:        the loop blocks for 2.7 intervals in an idle callback right after a tick, and Claude sleeps as long
--                 before its answer, as a machine that sleeps with Neovim does.
-- Promise: Claude is not dropped. big-message needs one of the two guards: the read callback clears the stamp on any
-- bytes (BytesClearStamp), or the check judges nothing after a block longer than 1.5 intervals (GapSkip). two-blocks
-- needs BytesClearStamp (the gap skip with a clear on a PONG only still drops Claude), and sleep needs GapSkip (the
-- any-bytes clear without the gap skip still drops Claude). The code of f3576ea has neither and breaks all three.
-- Model path: MachineSleeps, PollAndCheck (the check is skipped), TimerTicksAfterGap (the wake clears the stamp).
local H = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/harness.lua")
local INTERVAL = 200
local BIG = 300000
local SETTLE = 8 * INTERVAL

---Start the plugin and Claude, wait for the second ping, and run `block(client)` when the third ping goes out.
local function scenario(mode, block)
  local plugin = H.start_plugin(INTERVAL)
  local claude = H.spawn_claude(plugin.port, plugin.token, mode)
  local seen, pings = 0, 0
  H.wait(8000, function()
    local client = plugin.client()
    if client and client.state == "connected" and client.last_ping ~= seen then
      seen, pings = client.last_ping, pings + 1
    end
    return pings >= 2
  end)
  local client = assert(plugin.client(), "no client")
  seen = client.last_ping
  local blocked = block(client, seen)
  H.wait(SETTLE, function()
    return #plugin.disconnects > 0
  end)
  local dropped = plugin.disconnects[1]
  claude.kill()
  require("claudecode").stop()
  return blocked(), dropped
end

---A handle that runs `fn` once, in the iteration that runs the next tick, after the timers and before the poll.
local function once_before_poll(new_handle, client, seen, fn)
  local ran = false
  local handle = new_handle()
  handle:start(function()
    if not ran and client.last_ping ~= seen then
      ran = true
      handle:stop()
      fn()
    end
  end)
  return function()
    return ran
  end
end

local function check_kept(name, ran, dropped)
  H.check(
    name,
    ran and dropped == nil,
    dropped
        and string.format("on_disconnect(%s, %s, %q) at %d ms", dropped.id, dropped.code, dropped.reason, dropped.at)
      or (ran and "no on_disconnect, still listed" or "the block never ran")
  )
end

H.log("scenario big-message: block %d ms in an idle callback, Claude writes %d bytes and its pong", 2.7 * INTERVAL, BIG)
check_kept(
  "a pong behind 300 KB, after a block of 2.7 intervals before the poll",
  scenario("big:3:" .. BIG, function(client, seen)
    return once_before_poll(H.uv.new_idle, client, seen, function()
      H.uv.sleep(math.floor(2.7 * INTERVAL))
    end)
  end)
)

H.log("scenario two-blocks: 1.4 intervals in a check callback, then 1.4 intervals in an idle callback")
check_kept(
  "a pong behind 300 KB, after two blocks of 1.4 intervals",
  scenario("big:3:" .. BIG, function(client, seen)
    local ran = false
    local check = H.uv.new_check()
    check:start(function()
      if not ran and client.last_ping ~= seen then
        ran = true
        check:stop()
        H.uv.sleep(math.floor(1.4 * INTERVAL))
        local idle = H.uv.new_idle()
        local done = false
        idle:start(function()
          if not done then
            done = true
            idle:stop()
            H.uv.sleep(math.floor(1.4 * INTERVAL))
          end
        end)
      end
    end)
    return function()
      return ran
    end
  end)
)

H.log("scenario sleep: block %d ms in an idle callback, Claude sleeps as long before its answer", 2.7 * INTERVAL)
check_kept(
  "Claude that sleeps with Neovim for 2.7 intervals between a tick and its poll",
  scenario("late:3:" .. math.floor(2.7 * INTERVAL), function(client, seen)
    return once_before_poll(H.uv.new_idle, client, seen, function()
      H.uv.sleep(math.floor(2.7 * INTERVAL))
    end)
  end)
)
H.finish()
