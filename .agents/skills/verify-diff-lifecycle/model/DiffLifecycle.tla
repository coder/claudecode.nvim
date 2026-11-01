--------------------------- MODULE DiffLifecycle ---------------------------
(***************************************************************************)
(* The blocking openDiff answer in claudecode.nvim.                         *)
(*                                                                          *)
(* Claude calls openDiff and waits. The plugin must send exactly one answer *)
(* that matches what the user did (FILE_SAVED or DIFF_REJECTED), must not   *)
(* leave a waiting call with nothing that can answer it, and must not throw *)
(* away a diff the user accepted unless Claude asked for it, or the file   *)
(* or its buffer already holds the accepted text.                           *)
(*                                                                          *)
(* Each action is one synchronous run of Neovim's main loop. Code facts     *)
(* (BOOLEAN constants) are read from the source by check.sh: TRUE means the *)
(* guard is present in the code, FALSE models the code without it.         *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
  Reqs,      \* openDiff calls (model values)
  Tabs,      \* tab_name values Claude can use
  Clients,   \* WebSocket client ids (server/client.lua create_client)

  \* Code facts, see check.sh for the source line each one reads.
  GuardSaved,              \* diff.lua _resolve_diff_as_saved returns unless status == "pending"
  GuardRejected,           \* diff.lua _resolve_diff_as_rejected returns unless status == "pending"
  SenderCleared,           \* diff.lua resolution callback sets claude_deferred_responses[co_key] = nil
  ReplaceRejects,          \* diff.lua open_diff_blocking rejects a pending diff before replacing it
  ReplaceKeepsOthersSaved, \* diff.lua open_diff_blocking errors instead of replacing another client's saved diff
  CloseTabRejectsPending,  \* diff.lua close_diff_by_tab_name rejects a pending diff before cleanup
  CloseKeepsOthersSaved,   \* close_tab and closeAllDiffTabs pass the caller to close_diff_by_tab_name,
                           \* which keeps a saved diff that belongs to another client
  CloseEachByName,         \* diff.lua close_active_diffs closes each match through close_diff_by_tab_name
  CloseRechecksFilter,     \* diff.lua close_active_diffs rechecks each entry's filter right before it closes it
  CloseTakesRejected,      \* diff.lua close_active_diffs also closes an entry a handler rejected since the snapshot
  StopRejectsPending,      \* server/init.lua M.stop closes pending diffs before clearing senders
  StopPendingOnly,         \* diff.lua close_pending_diffs filters status == "pending"
  DisconnectRejects,       \* server/init.lua on_disconnect schedules close_diffs_for_client
  DisconnectPendingOnly,   \* diff.lua close_diffs_for_client filters status == "pending"
  UserCloseAllPendingOnly, \* init.lua :ClaudeCodeCloseAllDiffs calls close_pending_diffs
  UserCloseKeepsAcceptedText, \* diff.lua close_saved_diffs closes a saved diff only once its file or its buffer
                              \* holds the accepted text
  ClientTagged,            \* tools/init.lua passes the client to openDiff, which records client.id
  ClientIdsUnique,         \* server/client.lua numbers client ids, so a new connection never reuses one
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
  savedLost,  \* ghost: a saved diff was torn down while no connected owner could write it
  staleOwner, \* ghost: calls whose client id now names a later connection
  rejectedLeft \* ghost: a bulk close left open a diff from its list that a handler rejected

vars == <<phase, reqTab, reqClient, active, sender, answers, early, clientUp, serverUp, scheduled, savedLost,
          staleOwner, rejectedLeft>>

(* The parts of the state that one diff operation touches, as a record, so   *)
(* that a step that closes several diffs can chain the same operators.       *)
(* kept is not state: it holds the tabs whose file or file buffer holds the  *)
(* accepted text while :ClaudeCodeCloseAllDiffs runs, and is empty in every   *)
(* other step.                                                                *)
W == [phase |-> phase, active |-> active, sender |-> sender, answers |-> answers, early |-> early,
      savedLost |-> savedLost, rejectedLeft |-> rejectedLeft, kept |-> {}]

SetW(w) ==
  /\ phase' = w.phase
  /\ active' = w.active
  /\ sender' = w.sender
  /\ answers' = w.answers
  /\ early' = w.early
  /\ savedLost' = w.savedLost
  /\ rejectedLeft' = w.rejectedLeft

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

(* diff.lua _cleanup_diff_state: the entry leaves active_diffs. closer is the  *)
(* Claude client that asked for the close, or None for the user, a disconnect   *)
(* cleanup, or a server stop. A saved diff is lost unless its file or its      *)
(* buffer holds the accepted text, its own client closes it, or another client does while the    *)
(* owner is still connected to write it.                                        *)
Remove(w, t, closer) ==
  LET e == w.active[t]
      fresh == e # NoDiff /\ e.req \notin staleOwner
      lost == /\ e # NoDiff /\ e.status = "saved" /\ t \notin w.kept
              /\ ~(fresh /\ closer = reqClient[e.req])
              /\ (closer = None \/ ~(fresh /\ clientUp[reqClient[e.req]]))
  IN [w EXCEPT !.active[t] = NoDiff, !.savedLost = @ \/ lost]

(* diff.lua holds_edits_for_other_client: the user accepted the diff for a     *)
(* client other than c. Without ClientTagged, client_id is nil: nothing matches. *)
HeldForOther(w, t, c) ==
  /\ w.active[t] # NoDiff /\ w.active[t].status = "saved"
  /\ ClientTagged /\ reqClient[w.active[t].req] # c

(* diff.lua close_diff_by_tab_name(tab_name, client_id); None passes nil. *)
CloseByName(w, t, closer) ==
  IF w.active[t] = NoDiff \/ (CloseKeepsOthersSaved /\ closer # None /\ HeldForOther(w, t, closer)) THEN w
  ELSE Remove(IF w.active[t].status = "pending" /\ CloseTabRejectsPending
              THEN Resolve(w, t, "rejected") ELSE w, t, closer)

(* The filter_fn a bulk close passes to close_active_diffs: pendingOnly keeps   *)
(* status == "pending", and owner (a client or None) keeps that client's diffs. *)
(* SavedFilter is close_saved_diffs: status == "saved" and the file or its     *)
(* buffer holds the accepted text.                                              *)
Filter(pendingOnly, owner) == [pendingOnly |-> pendingOnly, owner |-> owner, savedOnly |-> FALSE]
SavedFilter == [pendingOnly |-> FALSE, owner |-> None, savedOnly |-> TRUE]

Matches(w, t, f) ==
  /\ w.active[t] # NoDiff
  /\ (w.active[t].status = "pending" \/ ~f.pendingOnly)
  /\ (f.owner = None \/ (ClientTagged /\ reqClient[w.active[t].req] = f.owner))
  /\ (~f.savedOnly \/ (w.active[t].status = "saved" /\ (t \in w.kept \/ ~UserCloseKeepsAcceptedText)))

(* Assumption, not a code fact: the user has a ClaudeCodeDiffClosed handler    *)
(* (README "Diff Lifecycle Events") that accepts or denies another open diff,  *)
(* for example with :ClaudeCodeDiffAccept in that diff's window.               *)
CONSTANT ClosedHandlerResolvesOther

(* _cleanup_diff_state fires ClaudeCodeDiffClosed synchronously after the      *)
(* entry leaves active_diffs. The handler resolves at most one other diff.     *)
AfterClosedEvent(w) ==
  {w} \cup IF ClosedHandlerResolvesOther THEN {Resolve(w, t, o) : t \in Tabs, o \in Outcomes} ELSE {}

(* diff.lua close_active_diffs: snapshot the matching tab names, then close each *)
(* in pairs() order, which is unspecified. The result is the set of states the  *)
(* user's ClaudeCodeDiffClosed handler can leave behind.                       *)
Rejected(w, t) == w.active[t] # NoDiff /\ w.active[t].status = "rejected"

RECURSIVE CloseEach(_, _, _, _)
CloseEach(w, S, f, closer) ==
  IF S = {} THEN {w}
  ELSE UNION {
         LET skip == IF CloseRechecksFilter THEN ~(Matches(w, t, f) \/ (CloseTakesRejected /\ Rejected(w, t)))
                     ELSE w.active[t] = NoDiff
             closed == IF CloseEachByName THEN CloseByName(w, t, closer) ELSE Remove(w, t, closer)
         IN UNION {CloseEach(v, S \ {t}, f, closer) : v \in IF skip THEN {w} ELSE AfterClosedEvent(closed)}
       : t \in S}

(* The whole bulk close from state w. It records when a diff from its list is *)
(* still open at the end because a ClaudeCodeDiffClosed handler rejected it.  *)
BulkClose(w, f, closer) ==
  LET S == {t \in Tabs : Matches(w, t, f)}
  IN {[v EXCEPT !.rejectedLeft = @ \/ \E t \in S : Rejected(v, t)] : v \in CloseEach(w, S, f, closer)}

CloseAll(f, closer) == BulkClose(W, f, closer)

Idle == \A r \in Reqs : phase[r] # "setup"
Open(t) == active[t] # NoDiff

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
  /\ staleOwner \subseteq Reqs
  /\ rejectedLeft \in BOOLEAN

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
  /\ staleOwner = {}
  /\ rejectedLeft = FALSE

(* tools/call openDiff -> open_diff_blocking up to the ClaudeCodeDiffOpened event. *)
(* When the tab_name holds another client's saved diff, open_diff_blocking     *)
(* errors before it touches that diff, and Claude gets the error at once.     *)
ClaudeOpensDiff(r, c, t) ==
  /\ Idle /\ serverUp /\ clientUp[c] /\ phase[r] = "unsent"
  /\ IF ReplaceKeepsOthersSaved /\ HeldForOther(W, t, c)
     THEN SetW([W EXCEPT !.phase[r] = "done", !.answers[r] = <<"ERROR">>])
     ELSE LET replaced == IF Open(t) /\ active[t].status = "pending" /\ ReplaceRejects
                          THEN Resolve(W, t, "rejected") ELSE W
              cleaned == Remove(replaced, t, c)
          IN SetW([cleaned EXCEPT !.active[t] = [req |-> r, status |-> "pending"],
                                  !.phase[r] = "setup"])
  /\ reqTab' = [reqTab EXCEPT ![r] = t]
  /\ reqClient' = [reqClient EXCEPT ![r] = c]
  /\ UNCHANGED <<clientUp, serverUp, scheduled, staleOwner>>

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
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled, staleOwner>>

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
  /\ UNCHANGED <<reqTab, reqClient, active, clientUp, serverUp, scheduled, savedLost, staleOwner, rejectedLeft>>

(* :w or :ClaudeCodeDiffAccept (BufWriteCmd / accept_current_diff). *)
UserAccepts(t) ==
  /\ Idle /\ Open(t)
  /\ Resolve(W, t, "saved") # W
  /\ SetW(Resolve(W, t, "saved"))
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled, staleOwner>>

(* :q, :bdelete, :ClaudeCodeDiffDeny (WinClosed / BufDelete / deny_current_diff). *)
UserRejects(t) ==
  /\ Idle /\ Open(t)
  /\ Resolve(W, t, "rejected") # W
  /\ SetW(Resolve(W, t, "rejected"))
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled, staleOwner>>

(* :ClaudeCodeCloseAllDiffs: close_pending_diffs, then close_saved_diffs. Its *)
(* first pass leaves the accepted text in some files or file buffers (ok), and *)
(* skips a diff whose file buffer already has unsaved changes.                 *)
UserClosesAllDiffs ==
  /\ Idle
  /\ \E t \in Tabs : Open(t)
  /\ \E v \in CloseAll(Filter(UserCloseAllPendingOnly, None), None), ok \in SUBSET Tabs :
       LET handed == [v EXCEPT !.kept = ok]
       IN \E u \in BulkClose(handed, SavedFilter, None) : SetW(u)
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled, staleOwner>>

(* tools/close_tab.lua, called by client c *)
ClaudeClosesTab(c, t) ==
  /\ Idle /\ serverUp /\ clientUp[c] /\ Open(t)
  /\ SetW(CloseByName(W, t, c))
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled, staleOwner>>

(* tools/close_all_diff_tabs.lua -> close_all_diffs (any status), called by client c *)
ClaudeClosesAllDiffTabs(c) ==
  /\ Idle /\ serverUp /\ clientUp[c]
  /\ \E t \in Tabs : Open(t)
  /\ \E v \in CloseAll(Filter(FALSE, None), c) : SetW(v)
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, scheduled, staleOwner>>

(* server/tcp.lua -> on_disconnect; the diff cleanup is vim.schedule'd. *)
ClientDisconnects(c) ==
  /\ Idle /\ serverUp /\ clientUp[c]
  /\ clientUp' = [clientUp EXCEPT ![c] = FALSE]
  /\ scheduled' = IF DisconnectRejects THEN scheduled \cup {c} ELSE scheduled
  /\ UNCHANGED <<phase, reqTab, reqClient, active, sender, answers, early, serverUp, savedLost, staleOwner,
                 rejectedLeft>>

(* Without ClientIdsUnique, a new connection can get the id of a client that  *)
(* disconnected, and the plugin takes it for the owner of that client's diffs. *)
ClientIdReused(c) ==
  /\ ~ClientIdsUnique /\ Idle /\ serverUp /\ ~clientUp[c]
  /\ clientUp' = [clientUp EXCEPT ![c] = TRUE]
  /\ staleOwner' = staleOwner \cup {r \in Reqs : reqClient[r] = c}
  /\ UNCHANGED <<phase, reqTab, reqClient, active, sender, answers, early, serverUp, scheduled, savedLost,
                 rejectedLeft>>

(* The scheduled close_diffs_for_client runs; its filter reads the table now. *)
DisconnectCleanupRuns(c) ==
  /\ Idle /\ c \in scheduled
  /\ scheduled' = scheduled \ {c}
  /\ \E v \in CloseAll(Filter(DisconnectPendingOnly, c), None) : SetW(v)
  /\ UNCHANGED <<reqTab, reqClient, clientUp, serverUp, staleOwner>>

(* server/init.lua M.stop: close pending diffs, stop the server (bypasses *)
(* on_disconnect), clear _G.claude_deferred_responses.                    *)
ServerStops ==
  /\ Idle /\ serverUp
  /\ serverUp' = FALSE
  /\ clientUp' = [c \in Clients |-> FALSE]
  /\ \E v \in IF StopRejectsPending THEN CloseAll(Filter(StopPendingOnly, None), None) ELSE {W} :
       SetW([v EXCEPT !.sender = [q \in Reqs |-> FALSE]])
  /\ UNCHANGED <<reqTab, reqClient, scheduled, staleOwner>>

Next ==
  \/ \E r \in Reqs, c \in Clients, t \in Tabs : ClaudeOpensDiff(r, c, t)
  \/ \E r \in Reqs, o \in Outcomes : UserHandlerResolves(r, o)
  \/ \E r \in Reqs : SetupEnds(r)
  \/ \E t \in Tabs : UserAccepts(t)
  \/ \E t \in Tabs : UserRejects(t)
  \/ UserClosesAllDiffs
  \/ \E c \in Clients, t \in Tabs : ClaudeClosesTab(c, t)
  \/ \E c \in Clients : ClaudeClosesAllDiffTabs(c)
  \/ \E c \in Clients : ClientDisconnects(c)
  \/ \E c \in Clients : ClientIdReused(c)
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

(* Only a Claude client (close_tab, closeAllDiffTabs, a replacing openDiff) *)
(* tears down a diff the user accepted, and only the client that owns it  *)
(* or another one while the owner is still connected to write the file.   *)
(* The user can too, once the file or its buffer holds the accepted text. *)
SavedDiffKept == ~savedLost

(* A bulk close leaves open no diff from its list that a ClaudeCodeDiffClosed *)
(* handler rejected while the loop ran: that diff holds no edits, and the user *)
(* asked for the bulk close.                                                   *)
NoRejectedLeftover == ~rejectedLeft

(* When a client disconnects, its waiting calls get answered without the *)
(* user doing anything.                                                 *)
DisconnectedCallsAnswered ==
  \A r \in Reqs :
    (phase[r] = "waiting" /\ reqClient[r] # None /\ ~clientUp[reqClient[r]]) ~> (phase[r] = "done")
=============================================================================
