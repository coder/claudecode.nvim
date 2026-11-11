-- Waits until Claude's handshake armed the flush (the 600 ms connection_wait_delay) while the mention is still queued:
-- the point the original replays reach with "the queue is empty" under the old design.
return function(L)
  return L.wait_for(
    1000,
    "the handshake arms the flush for after the 600 ms wait; the mention is still queued",
    function()
      return require("claudecode").state.mention_timer ~= nil and L.queue_len() >= 1
    end
  )
end
