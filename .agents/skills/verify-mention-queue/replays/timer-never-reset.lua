-- NoStrandedMention (finding 5): the connection timer once stayed set after it fired, so a mention queued later,
-- while Claude was still not connected, got no timeout and no error. Now each mention has its own deadline: both
-- mentions must leave the queue with an error, about connection_timeout + connection_wait_delay after their send.
-- Model path: YouSend, DeadlineFires, DeadlineRuns, YouSend, DeadlineFires, DeadlineRuns.
local L = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/lib.lua")
L.setup()
L.send(L.file("first.txt"))
L.wait_for(11500, "the deadline clears the first mention with an error", function()
  return #L.notices == 1 and L.queue_len() == 0
end)
L.send(L.file("second.txt"))
L.log("queue=%d connection timer=%s", L.queue_len(), L.timer_state())
L.wait_for(11500, "the deadline clears the second mention with an error", function()
  return #L.notices == 2 and L.queue_len() == 0
end)
L.log("queue=%d connection timer=%s notices=%d", L.queue_len(), L.timer_state(), #L.notices)
L.verdict(
  L.queue_len() == 0 and #L.notices == 2 and L.timer_state() == "nil",
  "NoStrandedMention",
  string.format(
    "a second mention after a timeout: queue=%d errors=%d timer=%s",
    L.queue_len(),
    #L.notices,
    L.timer_state()
  )
)
