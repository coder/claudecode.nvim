--------------------------- MODULE WsConnection ---------------------------
(***************************************************************************)
(* The life of one WebSocket connection to the claudecode.nvim server.     *)
(*                                                                          *)
(* Claude connects over TCP, sends its HTTP upgrade request, gets the 101   *)
(* reply, then sends requests and answers the plugin's pings. It can hang  *)
(* up, send a Close frame or a frame that breaks the protocol, or stop     *)
(* reading. The plugin can stop the server, and its ping timer drops a     *)
(* client that no longer answers.                                          *)
(*                                                                          *)
(* One step of the model is one indivisible step of the code: a libuv read *)
(* callback, a libuv write callback, the libuv close of a handle (which    *)
(* runs the pending write callbacks), a ping-timer tick, one vim.schedule'd *)
(* closure, or a main-loop command such as :ClaudeCodeStop.                *)
(*                                                                          *)
(* Writes follow libuv: uv_write puts the bytes into the kernel at once    *)
(* when nothing waits in the handle's write queue and the peer's receive   *)
(* window has room; its callback still runs in a later step. Otherwise the  *)
(* write waits in libuv's queue, and uv_close cancels it.                  *)
(*                                                                          *)
(* Code facts (BOOLEAN constants) are read from the source by check.sh:    *)
(* TRUE means the guard is in the code, FALSE models the code without it.  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Conns,       \* TCP connections the listener accepts (model values)
  PeerBudget,  \* frames Claude sends on one connection, its upgrade request included (pongs and the hang-up not counted)
  MaxSleeps,   \* how many ping-timer ticks run delayed: after a gap above interval * 1.5 (Neovim suspended or blocked), or late
  PeerEventuallyReads, \* assumption, not a code fact: Claude never stops reading for good
  \* Environment switches, not code facts. Each one allows the step of one bug this model found (see SKILL.md, "Bugs
  \* this model found"). They are TRUE in every run, so that a removed guard breaks the rule that its bug broke.
  GapDuringHandshake,        \* a tick gap above interval * 1.5 can come while a client is still in its handshake
  WindowFullOnProtocolClose, \* the plugin can read a frame that breaks the protocol while Claude's window is full
  StopBeforeOnClose,         \* the server can stop between a Close frame from Claude and its scheduled on_close
  LateTickAfterPing,         \* a tick can run late, 1.0 to 1.5 intervals after the one before: Neovim blocked right after a ping,
                             \* below the wake threshold, with Claude's pong still unread

  \* Code facts, see check.sh for the source lines each one reads.
  UpgradeInWriteCallback, \* client.lua process_data: `connected` and handshake_complete are set in the 101 write callback
  UpgradeRechecksState,   \* client.lua 101 write callback: returns when the state is no longer "upgrading" or the handle closes
  UpgradeStartsKeepalive, \* client.lua 101 write callback: sets client.last_pong when the client becomes connected
  DispatchGuard,          \* client.lua process_data: the scheduled on_message runs only for a connected client with an open handle
  PeerCloseMarksClosing,  \* client.lua process_data: a Close frame from Claude sets the state to "closing"
  DisconnectOnce,         \* tcp.lua _disconnect_client returns when the client is no longer in server.clients
  DisconnectClosesSocket, \* tcp.lua _remove_client closes the client's TCP handle (release_socket)
  UnlistedDisconnectReleases, \* tcp.lua _disconnect_client closes the handle of a client that is no longer in server.clients
  CloseWriteOwnsSocket,   \* tcp.lua release_socket leaves a handle alone while client.close_pending: its Close write callback closes it
  RejectClosesSocket,     \* client.lua: the write callback of a rejected handshake closes the handle
  ProtocolReportsAtOnce,  \* client.lua fail_connection: a protocol error runs close_client, then on_error, without waiting for the write
  StopWaitsForCloseWrite, \* tcp.lua stop_server only calls close_client; the Close write callback closes the handle
  KeepaliveReaps,         \* tcp.lua ping timer closes and disconnects a connected client that is not alive
  DropsOnSecondOverdueTick, \* tcp.lua ping timer: the first tick that finds no pong pings again and sets pong_overdue; the second drops
  AliveTickClearsOverdue, \* tcp.lua ping timer: a tick that finds the client alive clears pong_overdue
  PongResetsAge,          \* client.lua process_data: a PONG sets client.last_pong
  WakeResetsPong          \* tcp.lua ping timer: after a tick gap above interval * 1.5, last_pong of each connected client is reset

None == "none"
Frames == {"hello", "badhello", "req", "pong", "close", "bad", "eof"}
States == {"none", "connecting", "upgrading", "connected", "closing", "closed"}
CbKinds == {"101", "reject", "close"}   \* writes whose libuv callback does something
Min(a, b) == IF a < b THEN a ELSE b
Range(s) == {s[i] : i \in DOMAIN s}

VARIABLES
  st,        \* client.state; "none" until the listener accepts the connection
  hs,        \* client.handshake_complete
  listed,    \* the client is in server.clients
  handle,    \* the client's TCP handle: "none", "open", "closing" (uv_close called, write callbacks pending), "closed"
  kern,      \* writes the kernel took (or that failed) whose libuv callback has not run: sequence of [k, err]
  queued,    \* writes waiting in libuv's queue because Claude's receive window is full
  closeWhy,  \* why close_client wrote this client's Close frame: None, "protocol", "keepalive" or "stop". With st = "closing"
             \* it is client.close_pending, except for "keepalive": the ping timer clears close_pending
  buf,       \* frames read while the 101 reply is written (client.buffer)
  sched,     \* the vim.schedule queue (FIFO), records [c, k]
  age,       \* ping-timer ticks since the client's last pong (create_client sets last_pong): 3 means > interval * 2
  overdue,   \* client.pong_overdue: a tick found no pong for two intervals, and pinged again
  peer,      \* Claude's side: "idle", "live", "silent" (stopped reading and answering), "stuck" (silent, window full), "gone"
  inq,       \* frames Claude sent that the plugin has not read yet
  sent,      \* frames Claude has sent (PeerBudget bounds it)
  pingOut,   \* a ping reached Claude and Claude has not answered it yet
  serverUp,  \* the server and its ping timer run
  sleeps,    \* delayed ticks so far (after a gap above interval * 1.5, or late)
  \* ghosts: what the rules read
  awake,     \* ping-timer ticks of awake time since the last pong (or accept); a long gap counts as none
  upgraded,  \* the 101 reply was written without error
  ended,     \* the plugin started to close this connection, or saw it end
  reports,   \* on_disconnect calls for this client
  badDispatch, \* a request ran before its 101 reply was written, or after its connection ended
  dropped,   \* a Close frame for a protocol error or a server stop was cancelled by closing the handle
  falseTimeout \* the ping timer dropped a client that had less than 2 intervals of awake time without a pong

vars == <<st, hs, listed, handle, kern, queued, closeWhy, buf, sched, age, overdue, peer, inq, sent, pingOut, serverUp,
          sleeps, awake, upgraded, ended, reports, badDispatch, dropped, falseTimeout>>
env == <<peer, inq, sent, serverUp, sleeps>>

(* The plugin-side state as a record, so that a step that runs several      *)
(* functions in a row can chain the operators below.                        *)
W == [st |-> st, hs |-> hs, listed |-> listed, handle |-> handle, kern |-> kern, queued |-> queued,
      closeWhy |-> closeWhy, buf |-> buf, sched |-> sched, age |-> age, overdue |-> overdue, pingOut |-> pingOut,
      awake |-> awake,
      upgraded |-> upgraded, ended |-> ended, reports |-> reports, badDispatch |-> badDispatch,
      dropped |-> dropped, falseTimeout |-> falseTimeout]

SetW(w) ==
  /\ st' = w.st /\ hs' = w.hs /\ listed' = w.listed /\ handle' = w.handle /\ kern' = w.kern
  /\ queued' = w.queued /\ closeWhy' = w.closeWhy /\ buf' = w.buf /\ sched' = w.sched /\ age' = w.age
  /\ overdue' = w.overdue
  /\ pingOut' = w.pingOut /\ awake' = w.awake /\ upgraded' = w.upgraded /\ ended' = w.ended
  /\ reports' = w.reports /\ badDispatch' = w.badDispatch /\ dropped' = w.dropped /\ falseTimeout' = w.falseTimeout

(* tcp_handle:write(data, cb). k is "101", "reject" or "close" (a callback   *)
(* that does something), or "echo", "ping", "data" (no callback). A write on *)
(* a handle that is closing fails at once and its callback never runs.      *)
Write(w, c, k) ==
  IF w.handle[c] # "open" THEN w
  ELSE IF w.queued[c] # {} \/ peer[c] = "stuck"
  THEN [w EXCEPT !.queued[c] = @ \cup {k}]
  ELSE LET w1 == IF k \in CbKinds THEN [w EXCEPT !.kern[c] = Append(@, [k |-> k, err |-> peer[c] = "gone"])] ELSE w
       IN IF k = "ping" /\ peer[c] # "gone" THEN [w1 EXCEPT !.pingOut[c] = TRUE] ELSE w1

(* tcp_handle:close() (uv_close): the fd closes at once, and libuv cancels  *)
(* every write still in its queue. Their callbacks run with ECANCELED when   *)
(* the close finishes.                                                       *)
CloseHandle(w, c) ==
  IF w.handle[c] # "open" THEN w
  ELSE [w EXCEPT !.handle[c] = "closing",
                 !.kern[c] = IF "close" \in w.queued[c] THEN Append(@, [k |-> "close", err |-> TRUE]) ELSE @,
                 !.queued[c] = {},
                 !.ended[c] = TRUE,
                 !.dropped = @ \/ ("close" \in w.queued[c] /\ w.closeWhy[c] \in {"protocol", "stop"})]

Schedule(w, c, k) == [w EXCEPT !.sched = Append(@, [c |-> c, k |-> k])]

(* tcp.lua release_socket: close the handle unless the write callback of a queued Close frame     *)
(* will (client.close_pending, which the ping timer clears: a keepalive close does not wait).      *)
Release(w, c) ==
  IF CloseWriteOwnsSocket /\ w.st[c] = "closing" /\ w.closeWhy[c] \in {"protocol", "stop"} THEN w
  ELSE CloseHandle(w, c)

(* tcp.lua _disconnect_client, then _remove_client. A client that is no longer listed is only    *)
(* released.                                                                                      *)
Disconnect(w, c) ==
  LET w1 == [w EXCEPT !.ended[c] = TRUE]
  IN IF DisconnectOnce /\ ~w1.listed[c] THEN (IF UnlistedDisconnectReleases THEN Release(w1, c) ELSE w1)
     ELSE LET w2 == [w1 EXCEPT !.reports[c] = Min(@ + 1, 2)]
          IN IF ~w2.listed[c] THEN w2
             ELSE LET w3 == [w2 EXCEPT !.listed[c] = FALSE]
                  IN IF DisconnectClosesSocket THEN Release(w3, c) ELSE w3

(* client.lua close_client(client, code, reason). why names the caller.     *)
(* onDone is TRUE only in the mutant of ProtocolReportsAtOnce: the code     *)
(* without that guard reports the client from the Close write callback,     *)
(* as close_client's on_done did before the guard.                          *)
CloseClient(w, c, why, onDone) ==
  LET w0 == [w EXCEPT !.ended[c] = TRUE]
  IN IF w0.st[c] \in {"closing", "closed"} THEN (IF onDone THEN Schedule(w0, c, "done") ELSE w0)
     ELSE LET w1 == [w0 EXCEPT !.buf[c] = <<>>]
          IN IF w1.handle[c] # "open"
             THEN LET w2 == [w1 EXCEPT !.st[c] = "closed"] IN IF onDone THEN Schedule(w2, c, "done") ELSE w2
             ELSE IF w1.hs[c] \/ w1.st[c] = "upgrading"
                  THEN [Write([w1 EXCEPT !.closeWhy[c] = why], c, "close") EXCEPT !.st[c] = "closing"]
                  ELSE LET w2 == CloseHandle([w1 EXCEPT !.st[c] = "closed"], c)
                       IN IF onDone THEN Schedule(w2, c, "done") ELSE w2

(* client.lua fail_connection, on a frame that breaks the protocol (a frame that *)
(* parse_frame rejects, a data message that is binary, out of order, too big or  *)
(* not UTF-8): close_client, then on_error (_disconnect_client) at once. Without *)
(* the fact, on_error waits for the Close write callback.                         *)
ProtocolClose(w, c) ==
  IF ProtocolReportsAtOnce THEN Disconnect(CloseClient(w, c, "protocol", FALSE), c)
  ELSE CloseClient(w, c, "protocol", TRUE)

(* client.lua process_data on one frame of a read. *)
ProcessFrame(w, c, f) ==
  IF w.st[c] \in {"closing", "closed"} THEN [w EXCEPT !.buf[c] = <<>>]
  ELSE IF ~w.hs[c] THEN
         IF w.st[c] = "upgrading" THEN [w EXCEPT !.buf[c] = Append(@, f)]
         ELSE IF f = "hello"
         THEN IF UpgradeInWriteCallback THEN Write([w EXCEPT !.st[c] = "upgrading"], c, "101")
              ELSE Write([w EXCEPT !.st[c] = "connected", !.hs[c] = TRUE], c, "101")
         ELSE Write([w EXCEPT !.st[c] = "closing", !.ended[c] = TRUE], c, "reject")
  ELSE CASE f = "req" -> Schedule(w, c, "message")
         [] f = "pong" -> [w EXCEPT !.age[c] = IF PongResetsAge THEN 0 ELSE @, !.awake[c] = 0]
         [] f = "close" ->
              LET w1 == IF w.st[c] = "connected"
                        THEN [Write(w, c, "echo") EXCEPT !.st[c] = IF PeerCloseMarksClosing THEN "closing" ELSE @]
                        ELSE w
              IN Schedule([w1 EXCEPT !.ended[c] = TRUE, !.buf[c] = <<>>], c, "close")
         [] OTHER -> ProtocolClose([w EXCEPT !.buf[c] = <<>>], c)

(* The loop of one process_data call over several frames: it stops after a *)
(* Close frame or a protocol error.                                          *)
RECURSIVE ProcessAll(_, _, _)
ProcessAll(w, c, fs) ==
  IF fs = <<>> THEN w
  ELSE LET w1 == ProcessFrame(w, c, Head(fs))
       IN IF Head(fs) \in {"close", "bad"} THEN w1 ELSE ProcessAll(w1, c, Tail(fs))

(* The libuv callback of a write, with the error libuv passes. *)
Callback(w, c, e) ==
  CASE e.k = "101" ->
         \* client.lua process_data, the 101 write callback
         IF e.err THEN CloseHandle(Disconnect(w, c), c)
         ELSE LET w1 == [w EXCEPT !.upgraded[c] = TRUE]
              IN IF ~UpgradeInWriteCallback THEN w1
                 ELSE IF UpgradeRechecksState /\ (w1.st[c] # "upgrading" \/ w1.handle[c] # "open")
                      THEN [w1 EXCEPT !.buf[c] = <<>>]
                      ELSE ProcessAll([w1 EXCEPT !.hs[c] = TRUE, !.st[c] = "connected", !.buf[c] = <<>>,
                                                 !.age[c] = IF UpgradeStartsKeepalive THEN 0 ELSE @,
                                                 !.awake[c] = IF UpgradeStartsKeepalive THEN 0 ELSE @], c, w1.buf[c])
    [] e.k = "reject" ->
         \* client.lua process_data, the write callback of a rejected handshake: on_error, then close
         LET w1 == Disconnect(w, c) IN IF RejectClosesSocket THEN CloseHandle(w1, c) ELSE w1
    [] OTHER ->
         \* client.lua close_client, the Close write callback: closed, close the handle, then on_done
         LET w1 == CloseHandle([w EXCEPT !.st[c] = "closed"], c)
         IN IF w.closeWhy[c] = "protocol" /\ ~ProtocolReportsAtOnce THEN Disconnect(w1, c) ELSE w1

RECURSIVE RunAll(_, _, _)
RunAll(w, c, es) == IF es = <<>> THEN w ELSE RunAll(Callback(w, c, Head(es)), c, Tail(es))

(* One client of the ping timer's loop. mode: "normal" (on time), "late" (a block of 1.0 to 1.5 intervals     *)
(* delayed the tick: below the wake threshold, so no reset, and Claude's pong may still be unread, which      *)
(* leaves the last pong more than two intervals old) or "wake" (the tick gap was above interval * 1.5, so      *)
(* the clock jumped by more than two intervals). A block does not count as awake time.                        *)
TickOne(w, c, mode) ==
  IF ~w.listed[c] THEN w
  ELSE LET reset == mode = "wake" /\ WakeResetsPong /\ w.st[c] = "connected"
           w1 == [w EXCEPT !.age[c] = IF reset THEN 0
                                      ELSE IF mode = "wake" THEN 3
                                      ELSE IF mode = "late" THEN Min(@ + 2, 3)
                                      ELSE Min(@ + 1, 3),
                           !.awake[c] = IF mode = "wake" THEN @ ELSE Min(@ + 1, 3)]
       IN IF w1.st[c] # "connected" THEN w1
          ELSE IF ~KeepaliveReaps \/ w1.age[c] < 3
               THEN Write([w1 EXCEPT !.overdue[c] = IF AliveTickClearsOverdue THEN FALSE ELSE @], c, "ping")
          ELSE IF DropsOnSecondOverdueTick /\ ~w1.overdue[c] THEN Write([w1 EXCEPT !.overdue[c] = TRUE], c, "ping")
          ELSE Disconnect(CloseClient([w1 EXCEPT !.falseTimeout = @ \/ w1.awake[c] < 3], c, "keepalive", FALSE), c)

RECURSIVE TickAll(_, _, _)
TickAll(w, S, mode) ==
  IF S = {} THEN w ELSE LET c == CHOOSE x \in S : TRUE IN TickAll(TickOne(w, c, mode), S \ {c}, mode)

(* tcp.lua stop_server, one client. *)
StopOne(w, c) ==
  IF ~w.listed[c] THEN w
  ELSE LET w1 == CloseClient(w, c, "stop", FALSE) IN IF StopWaitsForCloseWrite THEN w1 ELSE CloseHandle(w1, c)

RECURSIVE StopAll(_, _)
StopAll(w, S) == IF S = {} THEN w ELSE LET c == CHOOSE x \in S : TRUE IN StopAll(StopOne(w, c), S \ {c})

Dead(c) == listed[c] /\ (peer[c] = "gone" \/ st[c] \in {"closing", "closed"} \/ (hs[c] /\ peer[c] \in {"silent", "stuck"}))

TypeOK ==
  /\ st \in [Conns -> States]
  /\ hs \in [Conns -> BOOLEAN]
  /\ listed \in [Conns -> BOOLEAN]
  /\ handle \in [Conns -> {"none", "open", "closing", "closed"}]
  /\ \A c \in Conns : kern[c] \in Seq([k : CbKinds, err : BOOLEAN]) /\ Len(kern[c]) <= 3
  /\ queued \in [Conns -> SUBSET {"data", "ping", "close", "echo"}]
  /\ closeWhy \in [Conns -> {None, "protocol", "keepalive", "stop"}]
  /\ \A c \in Conns : buf[c] \in Seq(Frames) /\ inq[c] \in Seq(Frames)
  /\ sched \in Seq([c : Conns, k : {"message", "close", "done"}])
  /\ age \in [Conns -> 0..3]
  /\ overdue \in [Conns -> BOOLEAN]
  /\ awake \in [Conns -> 0..3]
  /\ peer \in [Conns -> {"idle", "live", "silent", "stuck", "gone"}]
  /\ sent \in [Conns -> 0..PeerBudget]
  /\ pingOut \in [Conns -> BOOLEAN]
  /\ serverUp \in BOOLEAN
  /\ sleeps \in 0..MaxSleeps
  /\ upgraded \in [Conns -> BOOLEAN]
  /\ ended \in [Conns -> BOOLEAN]
  /\ reports \in [Conns -> 0..2]
  /\ badDispatch \in BOOLEAN
  /\ dropped \in BOOLEAN
  /\ falseTimeout \in BOOLEAN

Init ==
  /\ st = [c \in Conns |-> "none"]
  /\ hs = [c \in Conns |-> FALSE]
  /\ listed = [c \in Conns |-> FALSE]
  /\ handle = [c \in Conns |-> "none"]
  /\ kern = [c \in Conns |-> <<>>]
  /\ queued = [c \in Conns |-> {}]
  /\ closeWhy = [c \in Conns |-> None]
  /\ buf = [c \in Conns |-> <<>>]
  /\ sched = <<>>
  /\ age = [c \in Conns |-> 0]
  /\ overdue = [c \in Conns |-> FALSE]
  /\ peer = [c \in Conns |-> "idle"]
  /\ inq = [c \in Conns |-> <<>>]
  /\ sent = [c \in Conns |-> 0]
  /\ pingOut = [c \in Conns |-> FALSE]
  /\ serverUp = TRUE
  /\ sleeps = 0
  /\ awake = [c \in Conns |-> 0]
  /\ upgraded = [c \in Conns |-> FALSE]
  /\ ended = [c \in Conns |-> FALSE]
  /\ reports = [c \in Conns |-> 0]
  /\ badDispatch = FALSE
  /\ dropped = FALSE
  /\ falseTimeout = FALSE

-----------------------------------------------------------------------------
(* Steps of the plugin *)

(* tcp.lua _handle_new_connection: accept, create_client, add to server.clients, read_start, on_connect. *)
Accept(c) ==
  /\ serverUp /\ st[c] = "none"
  /\ SetW([W EXCEPT !.st[c] = "connecting", !.listed[c] = TRUE, !.handle[c] = "open"])
  /\ peer' = [peer EXCEPT ![c] = "live"]
  /\ UNCHANGED <<inq, sent, serverUp, sleeps>>

(* tcp.lua read_start callback with data -> client.lua process_data. One read carries one frame: *)
(* process_data handles the frames of one read in order and stops after a Close or a protocol   *)
(* error, so a read of several frames reaches no state that one-frame reads do not.             *)
Read(c) ==
  /\ handle[c] = "open" /\ inq[c] # <<>> /\ Head(inq[c]) # "eof"
  /\ WindowFullOnProtocolClose \/ ~(Head(inq[c]) = "bad" /\ peer[c] = "stuck")
  /\ SetW(ProcessFrame(W, c, Head(inq[c])))
  /\ inq' = [inq EXCEPT ![c] = Tail(@)]
  /\ UNCHANGED <<peer, sent, serverUp, sleeps>>

(* tcp.lua read_start callback with EOF or a read error -> _disconnect_client(1006). *)
ReadEOF(c) ==
  /\ handle[c] = "open" /\ inq[c] # <<>> /\ Head(inq[c]) = "eof"
  /\ SetW(Disconnect(W, c))
  /\ inq' = [inq EXCEPT ![c] = Tail(@)]
  /\ UNCHANGED <<peer, sent, serverUp, sleeps>>

(* libuv runs the callback of the oldest write the kernel took (client.lua: the 101 or reject *)
(* write callback in process_data, the Close write callback in close_client).                *)
WriteDone(c) ==
  /\ handle[c] = "open" /\ kern[c] # <<>>
  /\ SetW(Callback([W EXCEPT !.kern[c] = Tail(@)], c, Head(kern[c])))
  /\ UNCHANGED env

(* libuv finishes the uv_close of the handle: it runs every pending write callback in order, *)
(* the cancelled ones with ECANCELED.                                                         *)
CloseFinishes(c) ==
  /\ handle[c] = "closing"
  /\ SetW([RunAll([W EXCEPT !.kern[c] = <<>>], c, kern[c]) EXCEPT !.handle[c] = "closed"])
  /\ UNCHANGED env

(* One vim.schedule'd closure runs: client.lua's on_message wrapper (guarded), the on_close   *)
(* of a Close frame, or close_client's scheduled on_done; the last two call tcp.lua           *)
(* _disconnect_client.                                                                        *)
ScheduledRuns ==
  /\ sched # <<>>
  /\ LET e == Head(sched)
         c == e.c
         w0 == [W EXCEPT !.sched = Tail(@)]
     IN SetW(IF e.k = "message"
             THEN IF DispatchGuard => (w0.st[c] = "connected" /\ w0.handle[c] = "open")
                  THEN [w0 EXCEPT !.badDispatch = @ \/ ~w0.upgraded[c] \/ w0.ended[c]]
                  ELSE w0
             ELSE Disconnect(w0, c))
  /\ UNCHANGED env

(* tcp.lua start_ping_timer callback, a tick on time. *)
TimerTicks ==
  /\ serverUp
  /\ SetW(TickAll(W, Conns, "normal"))
  /\ UNCHANGED env

(* tcp.lua start_ping_timer callback after a gap above interval * 1.5: Neovim was suspended or *)
(* its main loop was blocked, so the loop's clock jumped.                                      *)
TimerTicksAfterGap ==
  /\ serverUp /\ sleeps < MaxSleeps
  /\ GapDuringHandshake \/ \A c \in Conns : ~(listed[c] /\ ~hs[c])
  /\ SetW(TickAll(W, Conns, "wake"))
  /\ sleeps' = sleeps + 1
  /\ UNCHANGED <<peer, inq, sent, serverUp>>

(* tcp.lua start_ping_timer callback after a block of 1.0 to 1.5 intervals. libuv runs the timer before it *)
(* reads the socket when the block ran in a callback after the poll phase (a check callback, or any block  *)
(* on Neovim 0.8), so the pong of the last ping is still unread. The gap is below interval * 1.5: no wake. *)
TimerTicksLate ==
  /\ LateTickAfterPing
  /\ serverUp /\ sleeps < MaxSleeps
  /\ SetW(TickAll(W, Conns, "late"))
  /\ sleeps' = sleeps + 1
  /\ UNCHANGED <<peer, inq, sent, serverUp>>

(* :ClaudeCodeStop or VimLeavePre: init.lua M.stop -> server/init.lua M.stop (stops the ping *)
(* timer) -> tcp.lua stop_server (close_client 1001 for each client, clients = {}).          *)
ServerStops ==
  /\ serverUp
  /\ StopBeforeOnClose \/ \A i \in DOMAIN sched : sched[i].k # "close"
  /\ SetW([StopAll(W, Conns) EXCEPT !.listed = [c \in Conns |-> FALSE]])
  /\ serverUp' = FALSE
  /\ UNCHANGED <<peer, inq, sent, sleeps>>

(* server/init.lua send / broadcast -> client.lua send_message while Claude does not read: the *)
(* message fills Claude's receive window, and the rest waits in libuv's queue.               *)
PluginSendsLarge(c) ==
  /\ peer[c] = "silent" /\ st[c] = "connected" /\ handle[c] = "open"
  /\ SetW([W EXCEPT !.queued[c] = @ \cup {"data"}])
  /\ peer' = [peer EXCEPT ![c] = "stuck"]
  /\ UNCHANGED <<inq, sent, serverUp, sleeps>>

-----------------------------------------------------------------------------
(* Steps of Claude (the environment) *)

(* Claude can write while it does not read: its process is busy, not gone. *)
ClaudeSends(c, f) ==
  /\ peer[c] \in {"live", "silent", "stuck"} /\ sent[c] < PeerBudget
  /\ f \in IF sent[c] = 0 THEN {"hello", "badhello"} ELSE {"req", "close", "bad"}
  /\ inq' = [inq EXCEPT ![c] = Append(@, f)]
  /\ sent' = [sent EXCEPT ![c] = @ + 1]
  /\ UNCHANGED <<st, hs, listed, handle, kern, queued, closeWhy, buf, sched, age, overdue, pingOut, awake, upgraded, ended,
                 reports, badDispatch, dropped, falseTimeout, peer, serverUp, sleeps>>

(* One unread pong answers as well as two, so Claude sends one only when none is unread. *)
ClaudeAnswersPing(c) ==
  /\ peer[c] = "live" /\ pingOut[c] /\ "pong" \notin Range(inq[c])
  /\ inq' = [inq EXCEPT ![c] = Append(@, "pong")]
  /\ pingOut' = [pingOut EXCEPT ![c] = FALSE]
  /\ UNCHANGED <<st, hs, listed, handle, kern, queued, closeWhy, buf, sched, age, overdue, awake, upgraded, ended, reports,
                 badDispatch, dropped, falseTimeout, peer, sent, serverUp, sleeps>>

(* Claude stops reading and answering (for example its process is suspended). *)
ClaudeStopsReading(c) ==
  /\ peer[c] = "live" /\ hs[c]
  /\ peer' = [peer EXCEPT ![c] = "silent"]
  /\ UNCHANGED <<st, hs, listed, handle, kern, queued, closeWhy, buf, sched, age, overdue, pingOut, awake, upgraded, ended,
                 reports, badDispatch, dropped, falseTimeout, inq, sent, serverUp, sleeps>>

(* Claude reads again; libuv's POLLOUT handler writes what waited in its queue. *)
ClaudeResumes(c) ==
  /\ peer[c] \in {"silent", "stuck"}
  /\ peer' = [peer EXCEPT ![c] = "live"]
  /\ SetW([W EXCEPT !.kern[c] = IF "close" \in queued[c] THEN Append(@, [k |-> "close", err |-> FALSE]) ELSE @,
                    !.pingOut[c] = @ \/ "ping" \in queued[c],
                    !.queued[c] = {}])
  /\ UNCHANGED <<inq, sent, serverUp, sleeps>>

(* Claude hangs up (FIN or RST). The plugin reads EOF after the frames before it, and writes *)
(* still in libuv's queue fail.                                                             *)
ClaudeHangsUp(c) ==
  /\ peer[c] \in {"live", "silent", "stuck"}
  /\ peer' = [peer EXCEPT ![c] = "gone"]
  /\ inq' = [inq EXCEPT ![c] = Append(@, "eof")]
  /\ SetW([W EXCEPT !.kern[c] = IF "close" \in queued[c] THEN Append(@, [k |-> "close", err |-> TRUE]) ELSE @,
                    !.queued[c] = {}])
  /\ UNCHANGED <<sent, serverUp, sleeps>>

Next ==
  \/ \E c \in Conns : Accept(c)
  \/ \E c \in Conns : Read(c)
  \/ \E c \in Conns : ReadEOF(c)
  \/ \E c \in Conns : WriteDone(c)
  \/ \E c \in Conns : CloseFinishes(c)
  \/ ScheduledRuns
  \/ TimerTicks
  \/ TimerTicksAfterGap
  \/ TimerTicksLate
  \/ ServerStops
  \/ \E c \in Conns : PluginSendsLarge(c)
  \/ \E c \in Conns, f \in Frames : ClaudeSends(c, f)
  \/ \E c \in Conns : ClaudeAnswersPing(c)
  \/ \E c \in Conns : ClaudeStopsReading(c)
  \/ \E c \in Conns : ClaudeResumes(c)
  \/ \E c \in Conns : ClaudeHangsUp(c)

(* libuv runs ready callbacks and timers, and the main loop runs scheduled closures. Claude is *)
(* never assumed to act, except that with PeerEventuallyReads it never stops reading for good. *)
Spec ==
  /\ Init /\ [][Next]_vars
  /\ \A c \in Conns : WF_vars(Read(c)) /\ WF_vars(ReadEOF(c)) /\ WF_vars(WriteDone(c)) /\ WF_vars(CloseFinishes(c))
  /\ WF_vars(ScheduledRuns)
  /\ WF_vars(TimerTicks)
  /\ \A c \in Conns : WF_vars(PeerEventuallyReads /\ ClaudeResumes(c))

-----------------------------------------------------------------------------
(* Rules *)

(* A request from Claude runs only after its 101 reply was written, and never after the  *)
(* plugin started to close the connection or saw it end.                                   *)
NoRequestAfterEnd == ~badDispatch

(* on_disconnect runs at most once per client. *)
DisconnectReportedOnce == \A c \in Conns : reports[c] <= 1

(* A Close frame for a protocol error (1002, 1003, 1007, 1009) or a server stop (1001) is  *)
(* written before the plugin closes the socket. The keepalive Close frame (1011) is not in *)
(* the rule: server/README.md documents that a peer whose window is full does not get it.  *)
StatusCloseDelivered == ~dropped

(* The ping timer drops a client only after two intervals of awake time without a pong:   *)
(* a suspended or blocked Neovim does not count against the client. It holds in every state, *)
(* written as a temporal formula so that check.sh checks it in a run of its own: its known   *)
(* finding is shorter than any other break, so in the joint run it would hide the others.    *)
NoFalseTimeout == [](~falseTimeout)

(* A client whose Claude hung up, stopped answering, or whose connection the plugin started *)
(* to close, eventually leaves server.clients with its on_disconnect, unless the server      *)
(* stops or Claude comes back.                                                                *)
DeadClientDropped ==
  \A c \in Conns : Dead(c) ~> ((~listed[c] /\ reports[c] >= 1) \/ ~serverUp \/ (peer[c] = "live" /\ st[c] = "connected"))

(* Once a client left server.clients (or the server stopped), its socket eventually closes. *)
(* Run with PeerEventuallyReads = TRUE.                                                      *)
DroppedSocketCloses == \A c \in Conns : (st[c] # "none" /\ ~listed[c]) ~> (handle[c] = "closed")
=============================================================================
