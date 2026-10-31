--------------------------- MODULE DiffLifecycle ---------------------------
(***************************************************************************)
(* The blocking openDiff answer in claudecode.nvim.                         *)
(*                                                                          *)
(* Claude calls openDiff and waits. The plugin must send exactly one answer *)
(* that matches what the user did (FILE_SAVED or DIFF_REJECTED), must not   *)
(* leave a waiting call with nothing that can answer it, and must not throw *)
(* away a diff the user accepted unless Claude asked for it.                *)
(*                                                                          *)
(* Each action is one synchronous run of Neovim's main loop. Code facts     *)
(* (BOOLEAN constants) are read from the source by check.sh: TRUE means the *)
(* guard is present in the code, FALSE models the code without it.         *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Reqs,      \* openDiff calls (model values)
  Tabs,      \* tab_name values Claude can use
  Clients,   \* WebSocket client ids (server/tcp.lua); an id never reconnects

  \* Code facts, see check.sh for the source line each one reads.
  GuardSaved,              \* diff.lua _resolve_diff_as_saved returns unless status == "pending"
  GuardRejected,           \* diff.lua _resolve_diff_as_rejected returns unless status == "pending"
  SenderCleared,           \* diff.lua resolution callback sets claude_deferred_responses[co_key] = nil
  ReplaceRejects,          \* diff.lua open_diff_blocking rejects a pending diff before replacing it
  CloseTabRejectsPending,  \* diff.lua close_diff_by_tab_name rejects a pending diff before cleanup
  CloseEachByName,         \* diff.lua close_active_diffs closes each match through close_diff_by_tab_name
  StopRejectsPending,      \* server/init.lua M.stop closes pending diffs before clearing senders
  StopPendingOnly,         \* diff.lua close_pending_diffs filters status == "pending"
  DisconnectRejects,       \* server/init.lua on_disconnect schedules close_diffs_for_client
  DisconnectPendingOnly,   \* diff.lua close_diffs_for_client filters status == "pending"
  UserCloseAllPendingOnly, \* init.lua :ClaudeCodeCloseAllDiffs calls close_pending_diffs
  ClientTagged,            \* tools/init.lua passes the client to openDiff, which records client.id
  SetupAnswerReturned,     \* diff.lua open_diff_blocking returns a result that arrives before its yield
  OpenedEventInSetup       \* diff.lua fires ClaudeCodeDiffOpened synchronously before the yield
                           \* (not a guard: TRUE lets a user handler resolve the diff in setup)

None == "none"
NoDiff == [req |-> None, status |-> None]
Outcomes == {"saved", "rejected"}

Answer(status) ==
  CASE status = "saved" -> "FILE_SAVED"
    [] status = "rejected" -> "DIFF_REJECTED"
    [] OTHER -> None

VARIABLES
  phase,      \* per call: "unsent", "setup" (coroutine running), "waiting" (yielded), "done"
  reqTab,     \* per call: its tab_name
  reqClient,  \* per call: the client that sent it
  active,     \* diff.lua active_diffs: per tab_name, the call it answers and its status
  sender,     \* per call: _G.claude_deferred_responses holds its response sender
  answers,    \* per call: the JSON-RPC responses the plugin sent, in order
  early,      \* per call: the answer kept for open_diff_blocking to return when setup ends
  clientUp,   \* per client: connected
  serverUp,   \* the WebSocket server runs
  scheduled,  \* clients whose vim.schedule'd disconnect cleanup has not run yet
  savedLost   \* ghost: a saved diff was torn down by something other than Claude

vars == <<phase, reqTab, reqClient, active, sender, answers, early, clientUp, serverUp, scheduled, savedLost>>

(* The parts of the state that one diff operation touches, as a record, so   *)
(* that a step that closes several diffs can chain the same operators.       *)
W == [phase |-> phase, active |-> active, sender |-> sender, answers |-> answers, early |-> early,
      savedLost |-> savedLost]

SetW(w) ==
  /\ phase' = w.phase
  /\ active' = w.active
  /\ sender' = w.sender
  /\ answers' = w.answers
  /\ early' = w.early
  /\ savedLost' = w.savedLost

(* diff.lua open_diff_blocking resolution callback. Before the yield it keeps *)
(* the result for open_diff_blocking to return. After the yield it calls      *)
(* coroutine.resume(co): resuming a dead coroutine fails, and the failure     *)
(* branch sends an error only if a sender is registered. Without the setup    *)
(* branch, resuming the running coroutine fails too, and no sender exists.    *)
Callback(w, q, msg) ==
  IF w.phase[q] = "setup" /\ SetupAnswerReturned
  THEN [w EXCEPT !.early[q] = msg]
  ELSE LET alive == w.phase[q] = "waiting"
           send == IF ~w.sender[q] THEN None ELSE IF alive THEN msg ELSE "ERROR"
       IN [w EXCEPT !.phase[q] = IF alive THEN "done" ELSE @,
                    !.answers[q] = IF send = None THEN @ ELSE Append(@, send),
                    !.sender[q] = IF send # None /\ SenderCleared THEN FALSE ELSE @]

(* diff.lua _resolve_diff_as_saved / _resolve_diff_as_rejected. *)
Resolve(w, t, outcome) ==
  LET e == w.active[t]
      guarded == IF outcome = "saved" THEN GuardSaved ELSE GuardRejected
  IN IF e = NoDiff \/ (guarded /\ e.status # "pending")
     THEN w
     ELSE Callback([w EXCEPT !.active[t].status = outcome], e.req, Answer(outcome))

(* diff.lua _cleanup_diff_state: the entry leaves active_diffs. *)
Remove(w, t, byClaude) ==
  [w EXCEPT !.active[t] = NoDiff,
            !.savedLost = @ \/ (~byClaude /\ w.active[t].status = "saved")]

(* diff.lua close_diff_by_tab_name. *)
CloseByName(w, t, byClaude) ==
  IF w.active[t] = NoDiff THEN w
  ELSE Remove(IF w.active[t].status = "pending" /\ CloseTabRejectsPending
              THEN Resolve(w, t, "rejected") ELSE w, t, byClaude)

(* diff.lua close_active_diffs: snapshot the matching tab names, then close each. *)
RECURSIVE CloseEach(_, _, _)
CloseEach(w, S, byClaude) ==
  IF S = {} THEN w
  ELSE LET t == CHOOSE x \in S : TRUE
       IN CloseEach(IF CloseEachByName THEN CloseByName(w, t, byClaude) ELSE Remove(w, t, byClaude),
                    S \ {t}, byClaude)

Idle == \A r \in Reqs : phase[r] # "setup"
ClaudeConnected == serverUp /\ \E c \in Clients : clientUp[c]
Open(t) == active[t] # NoDiff
PendingOr(t, keepOthers) == Open(t) /\ (active[t].status = "pending" \/ ~keepOthers)

TypeOK ==
  /\ phase \in [Reqs -> {"unsent", "setup", "waiting", "done"}]
  /\ reqTab \in [Reqs -> Tabs \cup {None}]
  /\ reqClient \in [Reqs -> Clients \cup {None}]
  /\ active \in [Tabs -> {NoDiff} \cup [req : Reqs, status : {"pending"} \cup Outcomes]]
  /\ sender \in [Reqs -> BOOLEAN]
  /\ answers \in [Reqs -> Seq({"FILE_SAVED", "DIFF_REJECTED", "ERROR"})]
  /\ early \in [Reqs -> {None, "FILE_SAVED", "DIFF_REJECTED"}]
  /\ clientUp \in [Clients -> BOOLEAN]
  /\ serverUp \in BOOLEAN
  /\ scheduled \subseteq Clients
  /\ savedLost \in BOOLEAN

Init ==
  /\ phase = [r \in Reqs |-> "unsent"]
  /\ reqTab = [r \in Reqs |-> None]
  /\ reqClient = [r \in Reqs |-> None]
  /\ active = [t \in Tabs |-> NoDiff]
  /\ sender = [r \in Reqs |-> FALSE]
  /\ answers = [r \in Reqs |-> <<>>]
  /\ early = [r \in Reqs |-> None]
  /\ clientUp = [c \in Clients |-> TRUE]
  /\ serverUp = TRUE
  /\ scheduled = {}
  /\ savedLost = FALSE

(* tools/call openDiff -> open_diff_blocking up to the ClaudeCodeDiffOpened event. *)
ClaudeOpensDiff(r, c, t) ==
  /\ Idle /\ serverUp /\ clientUp[c] /\ phase[r] = "unsent"
  /\ LET replaced == IF Open(t) /\ active[t].status = "pending" /\ ReplaceRejects
                     THEN Resolve(W, t, "rejected") ELSE W
         cleaned == Remove(replaced, t, TRUE)
     IN SetW([cleaned EXCEPT !.active[t] = [req |-> r, status |-> "pending"],
                             !.phase[r] = "setup"])
  /\ reqTab' = [reqTab EXCEPT ![r] = t]
  /\ reqClient' = [reqClient EXCEPT ![r] = c]
  /\ UNCHANGED <<clientUp, serverUp, scheduled>>

(* A user ClaudeCodeDiffOpened handler (README "Diff Lifecycle Events") runs *)
(* :ClaudeCodeDiffAccept or :ClaudeCodeDiffDeny, or closes the proposal     *)
(* window from a `nested = true` autocmd, before open_diff_blocking yields. *)
(* A default handler that closes the window resolves nothing: WinClosed     *)
(* does not fire inside a non-nested autocmd.                               *)
UserHandlerResolves(r, o) ==
  /\ OpenedEventInSetup
  /\ phase[r] = "setup"
  /\ Resolve(W, reqTab[r], o) # W
  /\ SetW(Resolve(W, reqTab[r], o))
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled>>

(* open_diff_blocking after setup. A kept answer is returned: the coroutine *)
(* ends, and tools/init.lua and server/init.lua send it as the immediate    *)
(* reply. Otherwise coroutine.yield(); tools/init.lua returns _deferred;    *)
(* server/init.lua stores the sender.                                       *)
SetupEnds(r) ==
  /\ phase[r] = "setup"
  /\ IF early[r] # None
     THEN /\ phase' = [phase EXCEPT ![r] = "done"]
          /\ answers' = [answers EXCEPT ![r] = Append(@, early[r])]
          /\ early' = [early EXCEPT ![r] = None]
          /\ UNCHANGED sender
     ELSE /\ phase' = [phase EXCEPT ![r] = "waiting"]
          /\ sender' = [sender EXCEPT ![r] = TRUE]
          /\ UNCHANGED <<answers, early>>
  /\ UNCHANGED <<reqTab, reqClient, active, clientUp, serverUp, scheduled, savedLost>>

(* :w or :ClaudeCodeDiffAccept (BufWriteCmd / accept_current_diff). *)
UserAccepts(t) ==
  /\ Idle /\ Open(t)
  /\ Resolve(W, t, "saved") # W
  /\ SetW(Resolve(W, t, "saved"))
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled>>

(* :q, :bdelete, :ClaudeCodeDiffDeny (WinClosed / BufDelete / deny_current_diff). *)
UserRejects(t) ==
  /\ Idle /\ Open(t)
  /\ Resolve(W, t, "rejected") # W
  /\ SetW(Resolve(W, t, "rejected"))
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled>>

(* :ClaudeCodeCloseAllDiffs *)
UserClosesAllDiffs ==
  /\ Idle
  /\ LET S == {t \in Tabs : PendingOr(t, UserCloseAllPendingOnly)}
     IN /\ S # {}
        /\ SetW(CloseEach(W, S, FALSE))
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled>>

(* tools/close_tab.lua *)
ClaudeClosesTab(t) ==
  /\ Idle /\ ClaudeConnected /\ Open(t)
  /\ SetW(CloseByName(W, t, TRUE))
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled>>

(* tools/close_all_diff_tabs.lua -> close_all_diffs (any status) *)
ClaudeClosesAllDiffTabs ==
  /\ Idle /\ ClaudeConnected
  /\ LET S == {t \in Tabs : Open(t)}
     IN /\ S # {}
        /\ SetW(CloseEach(W, S, TRUE))
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled>>

(* server/tcp.lua -> on_disconnect; the diff cleanup is vim.schedule'd. *)
ClientDisconnects(c) ==
  /\ Idle /\ serverUp /\ clientUp[c]
  /\ clientUp' = [clientUp EXCEPT ![c] = FALSE]
  /\ scheduled' = IF DisconnectRejects THEN scheduled \cup {c} ELSE scheduled
  /\ UNCHANGED <<phase, reqTab, reqClient, active, sender, answers, early, serverUp, savedLost>>

(* The scheduled close_diffs_for_client runs; its filter reads the table now. *)
DisconnectCleanupRuns(c) ==
  /\ Idle /\ c \in scheduled
  /\ scheduled' = scheduled \ {c}
  /\ LET S == {t \in Tabs : PendingOr(t, DisconnectPendingOnly) /\ ClientTagged /\ reqClient[active[t].req] = c}
     IN SetW(CloseEach(W, S, FALSE))
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp>>

(* server/init.lua M.stop: close pending diffs, stop the server (bypasses *)
(* on_disconnect), clear _G.claude_deferred_responses.                    *)
ServerStops ==
  /\ Idle /\ serverUp
  /\ serverUp' = FALSE
  /\ clientUp' = [c \in Clients |-> FALSE]
  /\ LET S == IF StopRejectsPending THEN {t \in Tabs : PendingOr(t, StopPendingOnly)} ELSE {}
         closed == CloseEach(W, S, FALSE)
     IN SetW([closed EXCEPT !.sender = [q \in Reqs |-> FALSE]])
  /\ UNCHANGED <<reqTab, reqClient, scheduled>>

Next ==
  \/ \E r \in Reqs, c \in Clients, t \in Tabs : ClaudeOpensDiff(r, c, t)
  \/ \E r \in Reqs, o \in Outcomes : UserHandlerResolves(r, o)
  \/ \E r \in Reqs : SetupEnds(r)
  \/ \E t \in Tabs : UserAccepts(t)
  \/ \E t \in Tabs : UserRejects(t)
  \/ UserClosesAllDiffs
  \/ \E t \in Tabs : ClaudeClosesTab(t)
  \/ ClaudeClosesAllDiffTabs
  \/ \E c \in Clients : ClientDisconnects(c)
  \/ \E c \in Clients : DisconnectCleanupRuns(c)
  \/ ServerStops

(* Setup is synchronous and the scheduled cleanup runs on a later tick. *)
Spec ==
  /\ Init /\ [][Next]_vars
  /\ \A r \in Reqs : WF_vars(SetupEnds(r))
  /\ \A c \in Clients : WF_vars(DisconnectCleanupRuns(c))

(* Only a model with both double-answer guards removed sends more than one *)
(* answer; this bound keeps that model finite.                            *)
AnswerBound == \A r \in Reqs : Len(answers[r]) <= 2

-----------------------------------------------------------------------------
(* Rules *)

(* Claude gets at most one response per openDiff call. *)
AtMostOneAnswer == \A r \in Reqs : Len(answers[r]) <= 1

(* While a diff stays open, its status agrees with what Claude was told. *)
AnswerMatchesDiff ==
  \A t \in Tabs : Open(t) /\ answers[active[t].req] # <<>> =>
    answers[active[t].req][1] = Answer(active[t].status)

(* A call that waits for the user still has a pending diff and a response *)
(* sender, so a user action or a teardown can answer it.                  *)
NoStrandedCall ==
  \A r \in Reqs : phase[r] = "waiting" =>
    /\ active[reqTab[r]].req = r
    /\ active[reqTab[r]].status = "pending"
    /\ sender[r]

(* Only Claude (close_tab, closeAllDiffTabs, a replacing openDiff) tears *)
(* down a diff the user accepted.                                       *)
SavedDiffKept == ~savedLost

(* When a client disconnects, its waiting calls get answered without the *)
(* user doing anything.                                                 *)
DisconnectedCallsAnswered ==
  \A r \in Reqs :
    (phase[r] = "waiting" /\ reqClient[r] # None /\ ~clientUp[reqClient[r]]) ~> (phase[r] = "done")
=============================================================================
