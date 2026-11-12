---------------------------- MODULE MentionQueue ----------------------------
(***************************************************************************)
(* The @ mention queue of claudecode.nvim and the WebSocket clients it     *)
(* sends to (lua/claudecode/init.lua and lua/claudecode/server/).          *)
(*                                                                          *)
(* A send that does not go out at once waits in one queue, oldest first.   *)
(* Two timers move it on. M.state.mention_timer is the next flush: a flush *)
(* sends only the head, only once some connected client has been connected *)
(* for connection_wait_delay ms, and the head leaves the queue only when a *)
(* connected client took the frame. M.state.connection_timer fires at the  *)
(* deadline of the oldest mention, connection_timeout +                    *)
(* connection_wait_delay ms after its send, and clears every mention whose *)
(* deadline passed with an error, unless a ready client is connected: then *)
(* the queue drains to it, and a flush that finds no ready client clears   *)
(* the overdue mentions. A timer's callback runs on the main loop and does *)
(* nothing once its timer was stopped or replaced.                         *)
(*                                                                          *)
(* One action is one indivisible step of Neovim's main loop. Timers are    *)
(* untimed: any pending timer can fire before any other, and the deadline  *)
(* of any queued mention can pass at any step. Two client slots model the  *)
(* broadcast to every connected client.                                    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Mentions, MaxConnects, MaxStarts,
  DeadlinesFire,           \* model switch: FALSE only for FlushDelivers, where no deadline passes
  \* Code facts. TRUE is the code as written.
  EnqueueArmsDeadline,     \* init.lua queue_mention starts connection_timer when none runs
  DeadlineReportsError,    \* init.lua expire_mentions calls logger.error before it removes the expired mentions
  DeadlineRearms,          \* init.lua expire_mentions starts connection_timer again for the oldest mention left
  DeadlineSparesReady,     \* init.lua expire_mentions clears nothing while a ready client is connected
  SparedQueueFlushes,      \* init.lua expire_mentions then calls schedule_mention_flush, so a flush is due
  FlushExpiresOverdue,     \* init.lua flush_mention_queue calls expire_mentions when it finds no ready client
  QueueKeepsDeadline,      \* init.lua schedule_mention_flush stops connection_timer only when the queue is empty
  HandshakeFlushes,        \* client.lua calls on_open after the 101 write; server/init.lua schedules process_mention_queue(true)
  ConnectedSchedulesFlush, \* init.lua schedule_mention_flush starts mention_timer while Claude is connected
  FlushWaitsForReady,      \* init.lua flush_mention_queue sends nothing while no connected client is ready
  WaitRearmsFlush,         \* init.lua flush_mention_queue starts mention_timer again for the end of that wait
  ReadyNeedsConnected,     \* init.lua ms_until_a_client_is_ready counts only clients in state "connected"
  ReadyFromHandshake,      \* client.lua sets connected_at when the handshake completes
  FlushSendsHead,          \* init.lua flush_mention_queue broadcasts the oldest mention, queue[1]
  FlushChecksDelivery,     \* init.lua flush_mention_queue keeps the head when no connected client took the frame
  FlushRemovesHead,        \* init.lua flush_mention_queue removes the head once a client took it
  FailedWriteReported,     \* a broadcast whose writes all failed shows an error (report_unwritten, tcp.lua broadcast)
  RefusedWriteReported,    \* client.lua send_message passes the error of a write that libuv refuses at once to its callback
  StopClearsQueue          \* init.lua M.stop calls clear_mention_queue (empties the queue, stops both timers)

M == 1..Mentions
C == 1..2

VARIABLES
  sent, queue, outcome, stopped,
  recv,        \* [C -> Seq(M)]: the mentions each client's Claude received, in order
  cstate,      \* [C -> client state]: "none", "connecting", "upgrading", "connected", "closing"
  age,         \* [C -> ...]: "fresh"; "accept" once connection_wait_delay has passed since the TCP accept;
               \* "handshake" once it has passed since the handshake too
  serverUp, connects, starts,
  flushTimer,  \* M.state.mention_timer: "nil", "running", or "fired" (its callback waits for the main loop)
  dlTimer,     \* M.state.connection_timer, the deadline timer: "nil", "running", or "fired"
  dlFor,       \* the mention whose deadline dlTimer was started for, 0 for none
  openRuns,    \* process_mention_queue(true) runs that on_open scheduled (a stop does not cancel them)
  early,       \* a mention went out while no connected client had been connected for connection_wait_delay
  luaError, leaked

vars == <<sent, queue, outcome, stopped, recv, cstate, age, serverUp, connects, starts, flushTimer, dlTimer, dlFor,
          openRuns, early, luaError, leaked>>

InSeq(m, s) == \E i \in 1..Len(s) : s[i] = m
Pending(m) == InSeq(m, queue)
Received(m) == \E c \in C : InSeq(m, recv[c])

(* init.lua M.is_claude_connected: a client in state "connected". *)
Connected == serverUp /\ \E c \in C : cstate[c] = "connected"

(* init.lua ms_until_a_client_is_ready: the clients it counts, and the ones that are ready by its reading. *)
Counted(c) == IF ReadyNeedsConnected THEN cstate[c] = "connected" ELSE cstate[c] \in {"connected", "closing"}
CodeReady(c) == Counted(c) /\ IF ReadyFromHandshake THEN age[c] = "handshake" ELSE age[c] \in {"accept", "handshake"}
WaitForReady == (\E c \in C : Counted(c)) /\ ~\E c \in C : CodeReady(c)
TrulyReady == \E c \in C : cstate[c] = "connected" /\ age[c] = "handshake"
AnyCodeReady == \E c \in C : CodeReady(c)

(* server/tcp.lua broadcast: the clients that take the frame. *)
Takers == {c \in C : cstate[c] = "connected"}

(* init.lua schedule_mention_flush(delay) with queue q and the timers ft (mention_timer) and dt (connection_timer, *)
(* started for df): the new <<ft, dt, df>>. An empty queue stops both timers.                                    *)
Schedule(q, ft, dt, df) ==
  IF q = <<>> THEN <<"nil", "nil", 0>>
  ELSE <<IF Connected /\ ConnectedSchedulesFlush /\ ft = "nil" THEN "running" ELSE ft,
         IF Connected /\ ~QueueKeepsDeadline THEN "nil" ELSE dt,
         IF Connected /\ ~QueueKeepsDeadline THEN 0 ELSE df>>

TypeOK ==
  /\ sent \in [M -> BOOLEAN]
  /\ queue \in Seq(M)
  /\ outcome \in [M -> {"none", "refused", "delivered", "failed", "lost", "errored", "silent", "cleared"}]
  /\ stopped \in [M -> BOOLEAN]
  /\ recv \in [C -> Seq(M)]
  /\ cstate \in [C -> {"none", "connecting", "upgrading", "connected", "closing"}]
  /\ age \in [C -> {"fresh", "accept", "handshake"}]
  /\ serverUp \in BOOLEAN
  /\ connects \in 0..MaxConnects
  /\ starts \in 0..MaxStarts
  /\ flushTimer \in {"nil", "running", "fired"}
  /\ dlTimer \in {"nil", "running", "fired"}
  /\ dlFor \in 0..Mentions
  /\ openRuns \in 0..MaxConnects
  /\ early \in BOOLEAN
  /\ luaError \in BOOLEAN
  /\ leaked \in BOOLEAN

Init ==
  /\ sent = [m \in M |-> FALSE]
  /\ queue = <<>>
  /\ outcome = [m \in M |-> "none"]
  /\ stopped = [m \in M |-> FALSE]
  /\ recv = [c \in C |-> <<>>]
  /\ cstate = [c \in C |-> "none"]
  /\ age = [c \in C |-> "fresh"]
  /\ serverUp = TRUE
  /\ connects = 0
  /\ starts = 0
  /\ flushTimer = "nil"
  /\ dlTimer = "nil"
  /\ dlFor = 0
  /\ openRuns = 0
  /\ early = FALSE
  /\ luaError = FALSE
  /\ leaked = FALSE

(* init.lua expire_mentions while no client is ready: the k oldest mentions, whose deadline passed, leave with one    *)
(* logger.error. The mention connection_timer was started for is the head if it still waits, and its deadline      *)
(* passed when the timer fired (from DeadlineRuns, atLeastOne), and any later deadline may have passed too. An empty *)
(* queue stops both timers, otherwise connection_timer runs again for the new head.                                 *)
Expire(k, ft) ==
  /\ k = 0 \/ DeadlinesFire
  /\ LET rest == SubSeq(queue, k + 1, Len(queue))
     IN /\ queue' = rest
        /\ outcome' = [m \in M |-> IF \E i \in 1..k : queue[i] = m
                                   THEN IF DeadlineReportsError THEN "errored" ELSE "silent"
                                   ELSE outcome[m]]
        /\ IF rest = <<>>
           THEN /\ flushTimer' = "nil"
                /\ dlTimer' = "nil"
                /\ dlFor' = 0
           ELSE /\ flushTimer' = ft
                /\ dlTimer' = IF DeadlineRearms THEN "running" ELSE "nil"
                /\ dlFor' = IF DeadlineRearms THEN Head(rest) ELSE 0

-----------------------------------------------------------------------------
(* You *)

(* init.lua M.send_at_mention: no server, an error. Otherwise              *)
(* queue_mention appends the mention with its deadline, starts            *)
(* connection_timer for it when none runs, then schedule_mention_flush.   *)
(* This is the default config only. With disable_broadcast_debouncing     *)
(* set, _broadcast_at_mention broadcasts at once while the queue is empty *)
(* and checks no readiness, so a Claude whose handshake just completed    *)
(* gets the mention early. That path is not modeled, and a PASS of        *)
(* SentWhenReady does not cover it (SKILL.md, "Scope and bounds").        *)
YouSend ==
  \E m \in M :
    /\ ~sent[m]
    /\ \A k \in M : k < m => sent[k]
    /\ sent' = [sent EXCEPT ![m] = TRUE]
    /\ IF ~serverUp
       THEN /\ outcome' = [outcome EXCEPT ![m] = "refused"]
            /\ UNCHANGED <<queue, flushTimer, dlTimer, dlFor>>
       ELSE LET q == Append(queue, m)
                arm == EnqueueArmsDeadline /\ dlTimer = "nil"
                t == Schedule(q, flushTimer, IF arm THEN "running" ELSE dlTimer, IF arm THEN m ELSE dlFor)
            IN /\ queue' = q
               /\ flushTimer' = t[1]
               /\ dlTimer' = t[2]
               /\ dlFor' = t[3]
               /\ UNCHANGED outcome
    /\ UNCHANGED <<stopped, recv, cstate, age, serverUp, connects, starts, openRuns, early, luaError, leaked>>

(* init.lua M.stop: the server closes every client, M.state.server = nil, *)
(* and clear_mention_queue empties the queue and stops both timers.        *)
YouStop ==
  /\ serverUp
  /\ serverUp' = FALSE
  /\ cstate' = [c \in C |-> "none"]
  /\ stopped' = [m \in M |-> stopped[m] \/ Pending(m)]
  /\ IF StopClearsQueue
     THEN /\ queue' = <<>>
          /\ outcome' = [m \in M |-> IF Pending(m) THEN "cleared" ELSE outcome[m]]
          /\ flushTimer' = "nil"
          /\ dlTimer' = "nil"
          /\ dlFor' = 0
     ELSE UNCHANGED <<queue, outcome, flushTimer, dlTimer, dlFor>>
  /\ UNCHANGED <<sent, recv, age, connects, starts, openRuns, early, luaError, leaked>>

YouStart ==
  /\ ~serverUp
  /\ starts < MaxStarts
  /\ serverUp' = TRUE
  /\ starts' = starts + 1
  /\ UNCHANGED <<sent, queue, outcome, stopped, recv, cstate, age, connects, flushTimer, dlTimer, dlFor, openRuns,
                 early, luaError, leaked>>

-----------------------------------------------------------------------------
(* Claude: each client slot *)

ClientOnly == UNCHANGED <<sent, queue, outcome, stopped, recv, serverUp, connects, starts, flushTimer, dlTimer, dlFor,
                          openRuns, early, luaError, leaked>>

(* server/tcp.lua _handle_new_connection: a new TCP client. *)
ClaudeConnects(c) ==
  /\ serverUp /\ cstate[c] = "none" /\ connects < MaxConnects
  /\ cstate' = [cstate EXCEPT ![c] = "connecting"]
  /\ age' = [age EXCEPT ![c] = "fresh"]
  /\ connects' = connects + 1
  /\ UNCHANGED <<sent, queue, outcome, stopped, recv, serverUp, starts, flushTimer, dlTimer, dlFor, openRuns, early,
                 luaError, leaked>>

ClaudeUpgrades(c) ==
  /\ cstate[c] = "connecting"
  /\ cstate' = [cstate EXCEPT ![c] = "upgrading"]
  /\ UNCHANGED age
  /\ ClientOnly

(* server/client.lua, the 101 write callback: handshake_complete, state  *)
(* "connected", connected_at, then on_open, which schedules               *)
(* process_mention_queue(true).                                            *)
HandshakeWritten(c) ==
  /\ cstate[c] = "upgrading"
  /\ cstate' = [cstate EXCEPT ![c] = "connected"]
  /\ openRuns' = IF HandshakeFlushes THEN openRuns + 1 ELSE openRuns
  /\ UNCHANGED <<sent, queue, outcome, stopped, recv, age, serverUp, connects, starts, flushTimer, dlTimer, dlFor,
                 early, luaError, leaked>>

(* connection_wait_delay passes since the TCP accept. *)
AcceptWaitPasses(c) ==
  /\ cstate[c] # "none" /\ age[c] = "fresh"
  /\ age' = [age EXCEPT ![c] = "accept"]
  /\ UNCHANGED cstate
  /\ ClientOnly

(* connection_wait_delay passes since the handshake, which came after the accept. *)
HandshakeWaitPasses(c) ==
  /\ cstate[c] = "connected" /\ age[c] = "accept"
  /\ age' = [age EXCEPT ![c] = "handshake"]
  /\ UNCHANGED cstate
  /\ ClientOnly

(* Claude sends its CLOSE frame: the client is "closing" until its socket closes. *)
ClaudeCloses(c) ==
  /\ cstate[c] = "connected"
  /\ cstate' = [cstate EXCEPT ![c] = "closing"]
  /\ UNCHANGED age
  /\ ClientOnly

CloseCallbackRuns(c) ==
  /\ cstate[c] = "closing"
  /\ cstate' = [cstate EXCEPT ![c] = "none"]
  /\ UNCHANGED age
  /\ ClientOnly

ClaudeDrops(c) ==
  /\ cstate[c] # "none"
  /\ cstate' = [cstate EXCEPT ![c] = "none"]
  /\ UNCHANGED age
  /\ ClientOnly

-----------------------------------------------------------------------------
(* The plugin's timers and scheduled callbacks *)

(* process_mention_queue(true): schedule_mention_flush(connection_wait_delay). *)
OpenRuns ==
  /\ openRuns > 0
  /\ openRuns' = openRuns - 1
  /\ LET t == Schedule(queue, flushTimer, dlTimer, dlFor)
     IN /\ flushTimer' = t[1]
        /\ dlTimer' = t[2]
        /\ dlFor' = t[3]
  /\ UNCHANGED <<sent, queue, outcome, stopped, recv, cstate, age, serverUp, connects, starts, early, luaError, leaked>>

FlushTimerFires ==
  /\ flushTimer = "running"
  /\ flushTimer' = "fired"
  /\ UNCHANGED <<sent, queue, outcome, stopped, recv, cstate, age, serverUp, connects, starts, dlTimer, dlFor, openRuns,
                 early, luaError, leaked>>

(* The flush callback, flush_mention_queue. An empty queue stops both     *)
(* timers. Otherwise assert(M.state.server). While some client counts but *)
(* none is ready, wait: mention_timer runs again. Otherwise broadcast the *)
(* head to every "connected" client. None took it: the head stays, and    *)
(* the next handshake or the deadline moves it. Taken: the head leaves,   *)
(* schedule_mention_flush(25 ms), and the writes finish: each write        *)
(* succeeds, or all fail later, or libuv refuses them at once.            *)
FlushRuns ==
  /\ flushTimer = "fired"
  /\ IF queue = <<>>
     THEN /\ flushTimer' = "nil"
          /\ dlTimer' = "nil"
          /\ dlFor' = 0
          /\ UNCHANGED <<queue, outcome, recv, early, luaError, leaked>>
     ELSE IF ~serverUp
     THEN /\ luaError' = TRUE
          /\ flushTimer' = "nil"
          /\ UNCHANGED <<queue, outcome, recv, dlTimer, dlFor, early, leaked>>
     ELSE IF FlushWaitsForReady /\ WaitForReady
     THEN IF FlushExpiresOverdue
          THEN /\ \E k \in 0..Len(queue) : Expire(k, IF WaitRearmsFlush THEN "running" ELSE "nil")
               /\ UNCHANGED <<recv, early, luaError, leaked>>
          ELSE /\ flushTimer' = IF WaitRearmsFlush THEN "running" ELSE "nil"
               /\ UNCHANGED <<queue, outcome, recv, dlTimer, dlFor, early, luaError, leaked>>
     ELSE LET took == Takers # {}
          IN IF ~took /\ FlushChecksDelivery
             THEN IF FlushExpiresOverdue
                  THEN /\ \E k \in 0..Len(queue) : Expire(k, "nil")
                       /\ UNCHANGED <<recv, early, luaError, leaked>>
                  ELSE /\ flushTimer' = "nil"
                       /\ UNCHANGED <<queue, outcome, recv, dlTimer, dlFor, early, luaError, leaked>>
             ELSE \E i \in (IF FlushSendsHead THEN 1..1 ELSE 1..Len(queue)), result \in {"written", "failed", "refused"} :
                    LET m == queue[i]
                        q == IF FlushRemovesHead THEN SubSeq(queue, 1, i - 1) \o SubSeq(queue, i + 1, Len(queue))
                             ELSE queue
                        t == Schedule(q, "nil", dlTimer, dlFor)
                        reported == IF result = "failed" THEN FailedWriteReported
                                    ELSE RefusedWriteReported /\ FailedWriteReported
                    IN /\ queue' = q
                       /\ outcome' = [outcome EXCEPT ![m] =
                                        IF ~took THEN "lost"
                                        ELSE IF result = "written" THEN "delivered"
                                        ELSE IF reported THEN "failed" ELSE "silent"]
                       /\ recv' = IF took /\ result = "written"
                                  THEN [c \in C |-> IF c \in Takers THEN Append(recv[c], m) ELSE recv[c]]
                                  ELSE recv
                       /\ early' = (early \/ (took /\ ~TrulyReady))
                       /\ leaked' = (leaked \/ (took /\ result = "written" /\ stopped[m]))
                       /\ flushTimer' = t[1]
                       /\ dlTimer' = t[2]
                       /\ dlFor' = t[3]
                       /\ UNCHANGED luaError
  /\ UNCHANGED <<sent, stopped, cstate, age, serverUp, connects, starts, openRuns>>

DeadlineFires ==
  /\ DeadlinesFire
  /\ dlTimer = "running"
  /\ dlTimer' = "fired"
  /\ UNCHANGED <<sent, queue, outcome, stopped, recv, cstate, age, serverUp, connects, starts, flushTimer, dlFor,
                 openRuns, early, luaError, leaked>>

(* The deadline callback, expire_mentions. While a ready client is        *)
(* connected, it clears nothing, makes sure a flush is due, and stops:    *)
(* the queue drains to that client. The handshake's on_open callback can  *)
(* still wait for the main loop then. Otherwise the mention it was        *)
(* started for is the head if it still waits, and its deadline passed.    *)
DeadlineRuns ==
  /\ dlTimer = "fired"
  /\ IF DeadlineSparesReady /\ AnyCodeReady
     THEN /\ dlTimer' = "nil"
          /\ dlFor' = 0
          /\ flushTimer' = IF SparedQueueFlushes THEN Schedule(queue, flushTimer, "nil", 0)[1] ELSE flushTimer
          /\ UNCHANGED <<queue, outcome>>
     ELSE \E k \in (IF dlFor # 0 /\ Pending(dlFor) THEN 1 ELSE 0)..Len(queue) : Expire(k, flushTimer)
  /\ UNCHANGED <<sent, stopped, recv, cstate, age, serverUp, connects, starts, openRuns, early, luaError, leaked>>

Done ==
  /\ \A m \in M : sent[m] /\ ~Pending(m)
  /\ UNCHANGED vars

Next ==
  \/ YouSend \/ YouStop \/ YouStart
  \/ \E c \in C : \/ ClaudeConnects(c) \/ ClaudeUpgrades(c) \/ HandshakeWritten(c) \/ AcceptWaitPasses(c)
                  \/ HandshakeWaitPasses(c) \/ ClaudeCloses(c) \/ CloseCallbackRuns(c) \/ ClaudeDrops(c)
  \/ OpenRuns \/ FlushTimerFires \/ FlushRuns \/ DeadlineFires \/ DeadlineRuns
  \/ Done

Spec ==
  /\ Init /\ [][Next]_vars
  /\ WF_vars(OpenRuns) /\ WF_vars(FlushTimerFires) /\ WF_vars(FlushRuns)
  /\ WF_vars(DeadlineFires) /\ WF_vars(DeadlineRuns)
  /\ \A c \in C : /\ WF_vars(HandshakeWritten(c)) /\ WF_vars(CloseCallbackRuns(c))
                  /\ WF_vars(AcceptWaitPasses(c)) /\ WF_vars(HandshakeWaitPasses(c))

RecvBound == \A c \in C : Len(recv[c]) <= Mentions + 1

-----------------------------------------------------------------------------
(* Rules *)

NoSilentDrop == \A m \in M : outcome[m] \in {"lost", "silent"} => stopped[m]
SentInOrder == \A c \in C : \A i, j \in 1..Len(recv[c]) : i < j => recv[c][i] <= recv[c][j]
AtMostOnce == \A c \in C : \A i, j \in 1..Len(recv[c]) : i # j => recv[c][i] # recv[c][j]
SentWhenReady == ~early
NothingAfterStop == ~luaError /\ ~leaked
NoStrandedMention == \A m \in M : Pending(m) ~> ~Pending(m)
WentOut(m) == outcome[m] \in {"delivered", "failed", "silent", "lost"}
ReadyDelivers == \A m \in M : (Pending(m) /\ TrulyReady) ~> (WentOut(m) \/ ~TrulyReady)
\* The same promise, checked where no deadline passes: the flushes alone must send the queue to a ready Claude.
FlushDelivers == ReadyDelivers
=============================================================================
