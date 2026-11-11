-- Waits until Claude's handshake started the 600 ms connection_wait_delay wait for the queued mention. Since #454 the
-- mention stays queued and the handshake arms the flush timer. Before #454 the handshake moved the queue into a
-- deferred batch, so the queue turned empty. Either point lets a replay act inside the wait on both designs.
return function(L)
  return L.wait_for(1000, "the handshake starts the 600 ms wait for the queued mention", function()
    local queued = L.queue_len()
    return (require("claudecode").state.mention_timer ~= nil and queued >= 1) or queued == 0
  end)
end
