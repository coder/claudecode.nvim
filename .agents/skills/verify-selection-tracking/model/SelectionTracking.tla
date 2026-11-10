------------------------- MODULE SelectionTracking -------------------------
(***************************************************************************)
(* What Claude sees as the user's current selection in claudecode.nvim.    *)
(*                                                                          *)
(* lua/claudecode/selection.lua pushes the selection to Claude as a         *)
(* selection_changed notification, and getCurrentSelection and             *)
(* getLatestSelection return the same value, M.state.latest_selection.      *)
(* Each send sets latest_selection first, so in this model `latest` is what *)
(* a connected Claude holds.                                                *)
(*                                                                          *)
(* The user moves, selects, edits and switches buffers. Autocmds run a      *)
(* synchronous flush on visual exit and restart a 100 ms debounce timer;    *)
(* the debounced update can start a demotion timer. Both are one-shot uv    *)
(* timers whose callback goes through vim.schedule, so a timer can fire,    *)
(* queue its callback, and be cancelled before the callback runs.          *)
(*                                                                          *)
(* One user step is one key (or command) with the autocmds it fires:       *)
(* ModeChanged, TextChanged, CursorMoved and BufEnter run in the same main- *)
(* loop iteration as the key, before Neovim polls libuv again, so no timer  *)
(* or scheduled callback can run between them. Each uv timer firing and    *)
(* each scheduled callback is its own step. The model has no clock: a timer *)
(* can fire after any number of user steps, which covers every value of    *)
(* visual_demotion_delay_ms (DelayBelowDebounce = TRUE adds the default     *)
(* 50 ms < 100 ms order).                                                   *)
(*                                                                          *)
(* Code facts (BOOLEAN constants) are read from the source by check.sh:     *)
(* TRUE means the guard is in the code, FALSE models the code without it.   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
  Files,      \* file buffers (model values)
  Term,       \* the Claude terminal buffer (terminal.get_active_terminal_bufnr)
  Pos,        \* cursor positions
  Ranges,     \* visual selection ranges
  None,       \* nil (model value)
  MaxEdits,   \* edits per file buffer (each one advances its changedtick)
  DelayBelowDebounce, \* environment: visual_demotion_delay_ms < debounce_ms, so a
                      \* demotion timer always fires before a later debounce timer
  WithTerminal,       \* environment: a Claude terminal buffer exists in Neovim (FALSE: terminal.provider
                      \* "none" or "external", Claude runs elsewhere)

  \* Code facts, see check.sh for the source lines each one reads.
  FlushOnVisualExit,     \* on_mode_changed calls flush_visual_selection when visual mode ends
  FlushSkipsOperator,    \* on_mode_changed records visual_entry; the flush returns when the
                         \* changedtick moved since then (an operator such as d consumed it)
  FlushSkipsTerminal,    \* flush_visual_selection returns in the Claude terminal buffer
  FlushRecordsCursor,    \* flush_visual_selection sets cursor_at_flush
  UpdateSkipsTerminal,   \* update_selection returns in the Claude terminal buffer
  PendingKeepsHeld,      \* update_selection keeps latest_selection while a demotion is
                         \* pending and the cursor stands where the flush left it
  ElseClearsHeldState,   \* update_selection's cursor branch clears last_active_visual_selection
                         \* and cursor_at_flush
  DemotionWaitsForMove,  \* handle_selection_demotion returns while the cursor is unmoved
  DemotionClearsHeldState, \* handle_selection_demotion clears the original buffer's
                           \* last_active_visual_selection and cursor_at_flush
  DebounceIgnoresStale,  \* the debounce callback returns unless it is M.state.debounce_timer
  DemotionIgnoresStale,  \* the demotion callback returns unless it is M.state.demotion_timer
  ClearsBeforeClose,     \* both cancel functions and both callbacks set the state field to
                         \* nil before timer:close()
  EntryClearsHeld,       \* on_mode_changed clears the held state when visual mode starts, except in the
                         \* Claude terminal
  FlushSkipReports,      \* a flush skipped for an operator clears the held state and, when Claude holds a
                         \* selection, reports the cursor at once
  PendingClearsHeld,     \* update_selection's pending-demotion branch clears the held state when it
                         \* reports the cursor
  ReconcileOnCursorMoved, \* on_cursor_moved calls reconcile_held_selection, and the BufEnter autocmd tells
                          \* it that the window cursor is not restored yet
  ReconcileOnTextChanged, \* on_text_changed calls reconcile_held_selection
  TextChangeReports,     \* reconcile reports the cursor when the text of the held selection changed
  MoveReports,           \* reconcile reports the cursor when it left the flushed position
  LeaveNoted,            \* reconcile notes another buffer entered (away) and ends the hold for one that is
                         \* not the Claude terminal (left)
  ReadRecordsTick        \* the flush and the in-visual update record selection_tick

Bufs == Files \cup {Term}
Modes == {"n", "v"}         \* "n" is every mode without a selection (normal, insert, terminal)

\* A selection value as has_selection_changed compares it: buffer (filePath), range or cursor
\* (start/end), and text. A visual selection's text is the text of its range at buffer version ver.
Vis(b, r, k) == [kind |-> "vis", buf |-> b, at |-> r, ver |-> k]
Cur(b, p) == [kind |-> "cur", buf |-> b, at |-> p, ver |-> 0]
VisValues == {Vis(b, r, k) : b \in Bufs, r \in Ranges, k \in 0..MaxEdits}
CurValues == {Cur(b, p) : b \in Bufs, p \in Pos}
Values == VisValues \cup CurValues

\* A timer field of M.state: nil, a running uv timer, a timer that fired and whose
\* vim.schedule'd callback waits, or (only without ClearsBeforeClose) a closed handle that
\* the field still holds, with or without a queued callback.
TStates == {"nil", "armed", "queued", "closed", "closedQueued"}
Alive == {"armed", "queued"}

P0 == CHOOSE p \in Pos : TRUE

VARIABLES
  \* Neovim
  buf,        \* the current buffer
  mode,       \* "v" in Visual or Select mode
  cur,        \* the window cursor
  vsel,       \* the live visual range, None outside visual mode
  ver,        \* per buffer: text version (changedtick)
  \* selection.lua M.state
  latest,     \* latest_selection: what Claude holds
  lastVis,    \* last_active_visual_selection.bufnr, or None
  cafBuf,     \* cursor_at_flush.bufnr, or None
  cafPos,     \* cursor_at_flush.pos
  cafLeft,    \* cursor_at_flush.left: the cursor left the flushed position or buffer, noted when it happened
  cafAway,    \* cursor_at_flush.away: a buffer entered since, not yet known to be the Claude terminal, or None
  rdBuf,      \* selection_tick.bufnr, or None
  rdVer,      \* selection_tick.tick (as a text version)
  entryBuf,   \* visual_entry.bufnr, or None
  entryVer,   \* visual_entry.tick
  db,         \* debounce_timer
  dbStale,    \* a callback of a cancelled debounce timer waits in the schedule queue
  dbLoose,    \* (only without DebounceIgnoresStale) a live debounce timer that the state lost
  dm,         \* demotion_timer
  dmBuf,      \* the buffer the demotion callback was scheduled for (current_buf)
  dmStale,    \* a callback of a cancelled demotion timer waits in the schedule queue
  dmLoose,    \* (only without DemotionIgnoresStale) buffers of live demotion timers the state lost
  \* ghosts
  phantom,    \* Claude was sent text at the '<,'> marks that an edit changed after the selection
  closedTwice,\* timer:close() ran on a closed handle: Lua error "handle ... is already closing"
  hold,       \* the selection the user released with Esc, until the cursor moves; or None
  holdPos,    \* the cursor when it was released
  holdLoose,  \* the user came back from the Claude terminal to it: either outcome is allowed
  released    \* the last step was the release itself

nvim == <<buf, mode, cur, vsel, ver>>
plugin == <<latest, lastVis, cafBuf, cafPos, cafLeft, cafAway, rdBuf, rdVer, entryBuf, entryVer, db, dbStale, dbLoose, dm, dmBuf, dmStale,
            dmLoose, phantom, closedTwice>>
spec == <<hold, holdPos, holdLoose, released>>
vars == <<nvim, plugin, spec>>

TypeOK ==
  /\ buf \in Bufs /\ mode \in Modes /\ cur \in Pos
  /\ vsel \in Ranges \cup {None} /\ (mode = "v") = (vsel # None)
  /\ ver \in [Bufs -> 0..MaxEdits] /\ ver[Term] = 0
  /\ latest \in Values \cup {None}
  /\ lastVis \in Bufs \cup {None}
  /\ cafBuf \in Bufs \cup {None} /\ cafPos \in Pos /\ cafLeft \in BOOLEAN /\ cafAway \in Bufs \cup {None}
  /\ rdBuf \in Bufs \cup {None} /\ rdVer \in 0..MaxEdits
  /\ entryBuf \in Bufs \cup {None} /\ entryVer \in 0..MaxEdits
  /\ db \in TStates /\ dbStale \in BOOLEAN /\ dbLoose \in BOOLEAN
  /\ dm \in TStates /\ dmBuf \in Bufs \cup {None} /\ (dm = "nil") = (dmBuf = None)
  /\ dmStale \in BOOLEAN /\ dmLoose \subseteq Bufs
  /\ phantom \in BOOLEAN /\ closedTwice \in BOOLEAN
  /\ hold \in VisValues \cup {None} /\ holdPos \in Pos /\ holdLoose \in BOOLEAN /\ released \in BOOLEAN

Init ==
  /\ buf = CHOOSE f \in Files : TRUE
  /\ mode = "n" /\ cur = P0 /\ vsel = None
  /\ ver = [b \in Bufs |-> 0]
  /\ latest = None /\ lastVis = None /\ cafBuf = None /\ cafPos = P0 /\ cafLeft = FALSE /\ cafAway = None /\ rdBuf = None /\ rdVer = 0 /\ entryBuf = None /\ entryVer = 0
  /\ db = "nil" /\ dbStale = FALSE /\ dbLoose = FALSE
  /\ dm = "nil" /\ dmBuf = None /\ dmStale = FALSE /\ dmLoose = {}
  /\ phantom = FALSE /\ closedTwice = FALSE
  /\ hold = None /\ holdPos = P0 /\ holdLoose = FALSE /\ released = FALSE

-----------------------------------------------------------------------------
(* The plugin's state as a record, so that the code's functions chain as    *)
(* operators over it. E is the Neovim state the code reads (after the key). *)

S == [latest |-> latest, lastVis |-> lastVis, cafBuf |-> cafBuf, cafPos |-> cafPos, cafLeft |-> cafLeft, cafAway |-> cafAway, rdBuf |-> rdBuf, rdVer |-> rdVer, entryBuf |-> entryBuf,
      entryVer |-> entryVer, db |-> db, dbStale |-> dbStale, dbLoose |-> dbLoose, dm |-> dm, dmBuf |-> dmBuf,
      dmStale |-> dmStale, dmLoose |-> dmLoose, phantom |-> phantom, closedTwice |-> closedTwice]

SetS(s) ==
  /\ latest' = s.latest /\ lastVis' = s.lastVis /\ cafBuf' = s.cafBuf
  /\ cafPos' = IF s.cafBuf = None THEN P0 ELSE s.cafPos
  /\ cafLeft' = IF s.cafBuf = None THEN FALSE ELSE s.cafLeft
  /\ cafAway' = IF s.cafBuf = None THEN None ELSE s.cafAway
  /\ rdBuf' = s.rdBuf /\ rdVer' = IF s.rdBuf = None THEN 0 ELSE s.rdVer
  /\ entryBuf' = s.entryBuf /\ entryVer' = s.entryVer
  /\ db' = s.db /\ dbStale' = s.dbStale /\ dbLoose' = s.dbLoose
  /\ dm' = s.dm /\ dmBuf' = IF s.dm = "nil" THEN None ELSE s.dmBuf
  /\ dmStale' = s.dmStale /\ dmLoose' = s.dmLoose
  /\ phantom' = s.phantom /\ closedTwice' = s.closedTwice

\* marks: the '<,'> marks that ending visual mode just set: the range and the buffer
\* version it was selected at. The flush reads them in the same step, so no state keeps them.
E == [buf |-> buf, mode |-> mode, cur |-> cur, vsel |-> vsel, marks |-> None, ver |-> ver]

\* has_selection_changed, then the send: latest_selection = sel; M.server.broadcast(...).
Publish(s, sel) == IF sel = s.latest THEN s ELSE [s EXCEPT !.latest = sel]

\* cursor_unmoved_since_flush(bufnr)
Unmoved(s, e) == s.cafBuf = e.buf /\ s.cafPos = e.cur /\ ~s.cafLeft

\* clear_held_state()
ClearHeld(s) == [s EXCEPT !.lastVis = None, !.cafBuf = None]

\* demote_if_selection_text_changed: the visual text in latest_selection was read in this buffer at another
\* text version than it has now.
TextChanged(s, e) == s.rdBuf = e.buf /\ s.latest \in VisValues /\ s.rdVer # e.ver[e.buf]

\* timer:stop(); timer:close() on the handle in state t. Closing a closed handle is an error.
CloseErr(t) == t \in {"closed", "closedQueued"}

\* _cancel_debounce_timer / _cancel_demotion_timer. Clearing the field first turns a queued
\* callback into a stale one. Without it the field keeps the closed handle.
Cancelled(t) ==
  CASE t = "nil" -> "nil"
    [] ClearsBeforeClose -> "nil"
    [] t \in {"armed", "closed"} -> "closed"
    [] OTHER -> "closedQueued"
NowStale(t) == ClearsBeforeClose /\ t \in {"queued", "closedQueued"}

CancelDebounce(s) ==
  [s EXCEPT !.db = Cancelled(s.db), !.dbStale = @ \/ NowStale(s.db), !.closedTwice = @ \/ CloseErr(s.db)]

CancelDemotion(s) ==
  [s EXCEPT !.dm = Cancelled(s.dm), !.dmStale = @ \/ NowStale(s.dm), !.closedTwice = @ \/ CloseErr(s.dm),
            !.dmBuf = IF Cancelled(s.dm) = "nil" THEN None ELSE @]

(* selection.lua debounce_update: cancel, then a new timer. A queued callback of the old *)
(* handle no longer matches M.state.debounce_timer, so it is stale.                       *)
DebounceUpdate(s) ==
  LET c == CancelDebounce(s)
  IN [c EXCEPT !.db = "armed", !.dbStale = @ \/ c.db = "closedQueued"]

(* selection.lua update_selection. *)
Update(s, e) ==
  LET here == e.buf
      orCursor(sel) == IF sel = None THEN Cur(here, e.cur) ELSE sel
  IN
  CASE here = Term /\ UpdateSkipsTerminal -> CancelDemotion(s)
    [] e.mode = "v" ->
         Publish([CancelDemotion(s) EXCEPT !.lastVis = here, !.rdBuf = IF ReadRecordsTick THEN here ELSE @,
                                           !.rdVer = IF ReadRecordsTick THEN e.ver[here] ELSE @],
                 Vis(here, e.vsel, e.ver[here]))
    [] s.dm # "nil" ->  \* `if M.state.demotion_timer then`: a pending demotion
         IF PendingKeepsHeld /\ Unmoved(s, e)
         THEN Publish(s, orCursor(s.latest))
         ELSE Publish(IF PendingClearsHeld THEN ClearHeld(s) ELSE s, orCursor(Cur(here, e.cur)))
    [] s.lastVis = here ->  \* just left visual mode here: keep it, start the demotion timer
         Publish([s EXCEPT !.dm = "armed", !.dmBuf = here], orCursor(s.latest))
    [] OTHER ->
         Publish([s EXCEPT !.lastVis = IF ElseClearsHeldState THEN None ELSE @,
                           !.cafBuf = IF ElseClearsHeldState THEN None ELSE @], Cur(here, e.cur))

(* selection.lua handle_selection_demotion(original_bufnr_when_scheduled). *)
Demote(s, e, b) ==
  LET clearVis(x) == [x EXCEPT !.lastVis = IF @ = b THEN None ELSE @]
      resolved(x) == IF DemotionClearsHeldState
                     THEN [clearVis(x) EXCEPT !.cafBuf = IF @ = b THEN None ELSE @]
                     ELSE x
  IN
  CASE e.buf = Term -> clearVis(s)                              \* Condition 1
    [] e.buf = b /\ e.mode = "v" -> clearVis(s)                 \* Condition 2
    [] e.buf = b /\ DemotionWaitsForMove /\ Unmoved(s, e) -> s  \* Condition 3, cursor unmoved
    [] e.buf = b -> resolved(Publish(s, Cur(b, e.cur)))         \* Condition 3, demote
    [] OTHER -> resolved(s)                                     \* another buffer

(* selection.lua flush_visual_selection, right after visual mode ended. *)
Flush(s, e) ==
  LET here == e.buf
      sel == Vis(here, e.marks.at, e.ver[here])  \* get_visual_selection_from_marks: the text there now
      rec == [s EXCEPT !.cafBuf = IF FlushRecordsCursor THEN here ELSE @,
                       !.cafPos = IF FlushRecordsCursor THEN e.cur ELSE @,
                       !.cafLeft = FALSE, !.cafAway = None,
                       !.rdBuf = IF ReadRecordsTick THEN here ELSE @,
                       !.rdVer = IF ReadRecordsTick THEN e.ver[here] ELSE @,
                       !.lastVis = here,
                       !.phantom = @ \/ (sel # s.latest /\ e.marks.ver # e.ver[here])]
  IN
  CASE here = Term /\ FlushSkipsTerminal -> s
    [] FlushSkipsOperator /\ s.entryBuf = here /\ s.entryVer # e.ver[here] ->
         IF ~FlushSkipReports THEN s
         ELSE IF s.latest \in VisValues THEN Update(ClearHeld(s), e)
         ELSE ClearHeld(s)
    [] OTHER -> Publish(CancelDemotion(rec), sel)

(* selection.lua on_mode_changed, then the debounce. *)
OnModeChanged(s, e, entering, leaving) ==
  LET entered == IF FlushSkipsOperator THEN [s EXCEPT !.entryBuf = e.buf, !.entryVer = e.ver[e.buf]] ELSE s
      s1 == CASE entering -> IF e.buf = Term \/ ~EntryClearsHeld THEN entered ELSE ClearHeld(entered)
              [] leaving /\ FlushOnVisualExit -> Flush(s, e)
              [] OTHER -> s
  IN DebounceUpdate(s1)

E2(b, m, c, v, mk, vr) == [buf |-> b, mode |-> m, cur |-> c, vsel |-> v, marks |-> mk, ver |-> vr]

\* reconcile_held_selection (on_cursor_moved, on_text_changed): changed text makes the plugin report the cursor at
\* once. A cursor that left the flushed position is reported at once (it is final at CursorMoved), another buffer is noted. At CursorMoved and TextChanged the
\* cursor is compared, at BufEnter it is not (Neovim restores it after the event). Entering the Claude terminal
\* keeps the hold and cancels the pending demotion.
\* termKnown: is_claude_terminal_buffer(current buffer) at this event. A new Claude terminal is not registered when
\* BufEnter fires, so then it may be FALSE: the buffer is noted in cafAway and decided at the next event.
Reconcile(s, e, compareCursor, termKnown) ==
  IF TextChangeReports /\ TextChanged(s, e) THEN Update(ClearHeld(s), e)
  ELSE IF s.cafBuf = None \/ s.cafLeft THEN s
  ELSE LET awayGone == LeaveNoted /\ s.cafAway # None /\ s.cafAway # e.buf
       IN IF awayGone /\ s.cafAway # Term THEN [s EXCEPT !.cafLeft = TRUE]
          ELSE LET s1 == IF awayGone THEN [s EXCEPT !.cafAway = None] ELSE s
               IN IF e.buf = Term /\ termKnown THEN CancelDemotion([s1 EXCEPT !.cafAway = None])
                  ELSE IF LeaveNoted /\ s1.cafBuf # e.buf THEN [s1 EXCEPT !.cafAway = e.buf]
                  ELSE IF MoveReports /\ compareCursor /\ ~Unmoved(s1, e) THEN Update(ClearHeld(s1), e)
                  ELSE s1

\* The two handlers that call it. A key that edits the cursor line (x) fires CursorMoved, then TextChanged.
OnCursor(s, e, compareCursor, termKnown) == IF ReconcileOnCursorMoved THEN Reconcile(s, e, compareCursor, termKnown) ELSE s
OnText(s, e) == IF ReconcileOnTextChanged THEN Reconcile(s, e, TRUE, TRUE) ELSE s

NoSpecChange == UNCHANGED <<hold, holdPos, holdLoose>> /\ released' = FALSE
DropHold == hold' = None /\ holdPos' = P0 /\ holdLoose' = FALSE /\ released' = FALSE

-----------------------------------------------------------------------------
(* The user. Each step is one key or command with the autocmds it fires.   *)

(* v, V, CTRL-V or gv: ModeChanged (entering visual). *)
YouStartSelecting(r) ==
  /\ mode = "n"
  /\ mode' = "v" /\ vsel' = r
  /\ SetS(OnModeChanged(S, E2(buf, "v", cur, r, None, ver), TRUE, FALSE))
  /\ UNCHANGED <<buf, cur, ver>>
  /\ IF buf \in Files THEN DropHold ELSE NoSpecChange

(* A motion in visual mode: CursorMoved. *)
YouExtendSelection(r, p) ==
  /\ mode = "v" /\ <<r, p>> # <<vsel, cur>>
  /\ vsel' = r /\ cur' = p
  /\ SetS(DebounceUpdate(OnCursor(S, E2(buf, "v", p, r, None, ver), TRUE, TRUE)))
  /\ UNCHANGED <<buf, mode, ver>>
  /\ NoSpecChange

(* Esc (or a window command) ends visual mode: Neovim sets '<,'>, then ModeChanged. *)
YouReleaseSelection ==
  /\ mode = "v"
  /\ SetS(OnModeChanged(S, E2(buf, "n", cur, None, [at |-> vsel, ver |-> ver[buf]], ver), FALSE, TRUE))
  /\ mode' = "n" /\ vsel' = None
  /\ UNCHANGED <<buf, cur, ver>>
  /\ IF buf \in Files
     THEN hold' = Vis(buf, vsel, ver[buf]) /\ holdPos' = cur /\ holdLoose' = FALSE /\ released' = TRUE
     ELSE NoSpecChange

(* d, c, x, > or another operator on the selection: the text changes, visual mode ends *)
(* (ModeChanged sees the new changedtick) and the cursor lands on p. CursorMoved and    *)
(* TextChanged fire when Neovim waits for the next key, so a mapping, a macro or         *)
(* typeahead runs the next key first. The step leaves them out: it is the case in which  *)
(* they have not fired yet.                                                              *)
YouEditSelection(p) ==
  /\ buf \in Files /\ mode = "v" /\ ver[buf] < MaxEdits
  /\ LET vr == [ver EXCEPT ![buf] = @ + 1]
     IN /\ ver' = vr
        /\ SetS(DebounceUpdate(OnModeChanged(S, E2(buf, "n", p, None, [at |-> vsel, ver |-> ver[buf]], vr),
                                              FALSE, TRUE)))
  /\ mode' = "n" /\ vsel' = None /\ cur' = p
  /\ UNCHANGED buf
  /\ DropHold

(* A motion in a file: CursorMoved. *)
YouMoveCursor(p) ==
  /\ buf \in Files /\ mode = "n" /\ p # cur
  /\ cur' = p
  /\ SetS(DebounceUpdate(OnCursor(S, E2(buf, "n", p, None, None, ver), TRUE, TRUE)))
  /\ UNCHANGED <<buf, mode, vsel, ver>>
  /\ DropHold

(* x or r at the cursor: the text under the cursor changes, the cursor stays. TextChanged. *)
YouEditAtCursor ==
  /\ buf \in Files /\ mode = "n" /\ ver[buf] < MaxEdits
  /\ ver' = [ver EXCEPT ![buf] = @ + 1]
  /\ SetS(DebounceUpdate(OnText(OnCursor(S, E2(buf, "n", cur, None, None, ver'), TRUE, TRUE), E2(buf, "n", cur, None, None, ver'))))
  /\ UNCHANGED <<buf, mode, cur, vsel>>
  /\ NoSpecChange

(* A plugin, a reload or a command changes text away from the cursor, and the held text *)
(* with it: TextChanged fires, CursorMoved does not.                                    *)
YouEditByPlugin ==
  /\ buf \in Files /\ mode = "n" /\ ver[buf] < MaxEdits
  /\ ver' = [ver EXCEPT ![buf] = @ + 1]
  /\ SetS(DebounceUpdate(OnText(S, E2(buf, "n", cur, None, None, ver'))))
  /\ UNCHANGED <<buf, mode, cur, vsel>>
  /\ NoSpecChange

(* A change that leaves the cursor and any held selection alone (a line below it, or a *)
(* reload): TextChanged.                                                               *)
YouEditElsewhere ==
  /\ buf \in Files /\ mode = "n"
  /\ SetS(DebounceUpdate(OnText(S, E)))
  /\ UNCHANGED nvim
  /\ NoSpecChange

(* :b, a window command or a click into buffer b with the cursor at p: BufEnter. *)
(* In the Claude terminal the held selection stays. Back in its file with the    *)
(* cursor where it was, Claude may keep it or get the cursor.                    *)
YouSwitchBuffer(b, p) ==
  /\ mode = "n" /\ b # buf
  /\ b = Term => WithTerminal /\ p = P0
  /\ buf' = b /\ cur' = p
  /\ \E cursorMoved, termKnown \in BOOLEAN :
       \* Without CursorMoved the cursor lands where the window had it, and a :b lands on the buffer's remembered
       \* position, which is the one the plugin recorded: every later move would have set left.
       /\ ~cursorMoved => (p = cur /\ (cafBuf = b /\ ~cafLeft => p = cafPos))
       /\ LET e2 == E2(b, "n", p, None, None, ver)
              entered == OnCursor(S, e2, FALSE, termKnown)
          IN SetS(DebounceUpdate(IF cursorMoved THEN OnCursor(entered, e2, TRUE, TRUE) ELSE entered))
  /\ UNCHANGED <<mode, vsel, ver>>
  /\ IF b = Term
     THEN NoSpecChange
     ELSE IF buf = Term /\ hold # None /\ hold.buf = b /\ p = holdPos
          THEN holdLoose' = TRUE /\ UNCHANGED <<hold, holdPos>> /\ released' = FALSE
          ELSE DropHold

-----------------------------------------------------------------------------
(* The timers. uv fires a timer; schedule_wrap queues its callback; the    *)
(* callback runs later on the main loop.                                   *)

(* The debounce uv timer fires. With the default delays, a pending demotion fires first. *)
DebounceTimerFires ==
  /\ db = "armed"
  /\ DelayBelowDebounce => dm \notin Alive
  /\ db' = "queued"
  /\ UNCHANGED <<nvim, latest, lastVis, cafBuf, cafPos, cafLeft, cafAway, rdBuf, rdVer, entryBuf, entryVer, dbStale, dbLoose, dm, dmBuf, dmStale,
                 dmLoose, phantom, closedTwice>>
  /\ NoSpecChange

(* debounce_update's callback for the current timer: clear the field, close, update_selection. *)
DebounceCallbackRuns ==
  /\ db \in {"queued", "closedQueued"}
  /\ LET s1 == [S EXCEPT !.db = IF ClearsBeforeClose THEN "nil" ELSE "closed", !.closedTwice = @ \/ CloseErr(db)]
     IN SetS(IF CloseErr(db) THEN s1 ELSE Update(s1, E))  \* the close error aborts the callback
  /\ UNCHANGED nvim
  /\ NoSpecChange

(* A callback of a cancelled debounce timer. With the identity check it returns. *)
(* Without it, it clears the field (losing the live timer), and its close errors. *)
StaleDebounceCallbackRuns ==
  /\ dbStale
  /\ dbStale' \in BOOLEAN  \* other stale callbacks can wait behind it
  /\ IF DebounceIgnoresStale
     THEN UNCHANGED <<db, dbLoose, closedTwice>>
     ELSE /\ db' = IF ClearsBeforeClose THEN "nil" ELSE db
          /\ dbLoose' = (dbLoose \/ (ClearsBeforeClose /\ db \in Alive))
          /\ closedTwice' = TRUE
  /\ UNCHANGED <<nvim, latest, lastVis, cafBuf, cafPos, cafLeft, cafAway, rdBuf, rdVer, entryBuf, entryVer, dm, dmBuf, dmStale, dmLoose, phantom>>
  /\ NoSpecChange

(* Without the identity check: a live debounce timer the field lost fires and runs in full. *)
LooseDebounceCallbackRuns ==
  /\ dbLoose
  /\ \E keep \in BOOLEAN :  \* other lost timers can still be live
       SetS(Update([S EXCEPT !.db = "nil", !.dbLoose = keep \/ db \in Alive], E))
  /\ UNCHANGED nvim
  /\ NoSpecChange

DemotionTimerFires ==
  /\ dm = "armed"
  /\ dm' = "queued"
  /\ UNCHANGED <<nvim, latest, lastVis, cafBuf, cafPos, cafLeft, cafAway, rdBuf, rdVer, entryBuf, entryVer, db, dbStale, dbLoose, dmBuf, dmStale,
                 dmLoose, phantom, closedTwice>>
  /\ NoSpecChange

(* update_selection's demotion callback: clear the field, close, handle_selection_demotion. *)
DemotionCallbackRuns ==
  /\ dm \in {"queued", "closedQueued"}
  /\ LET s1 == [S EXCEPT !.dm = IF ClearsBeforeClose THEN "nil" ELSE "closed", !.closedTwice = @ \/ CloseErr(dm)]
     IN SetS(IF CloseErr(dm) THEN s1 ELSE Demote(s1, E, dmBuf))
  /\ UNCHANGED nvim
  /\ NoSpecChange

StaleDemotionCallbackRuns ==
  /\ dmStale
  /\ dmStale' \in BOOLEAN
  /\ IF DemotionIgnoresStale
     THEN UNCHANGED <<dm, dmBuf, dmLoose, closedTwice>>
     ELSE /\ dm' = IF ClearsBeforeClose THEN "nil" ELSE dm
          /\ dmBuf' = IF ClearsBeforeClose THEN None ELSE dmBuf
          /\ dmLoose' = IF ClearsBeforeClose /\ dm \in Alive THEN dmLoose \cup {dmBuf} ELSE dmLoose
          /\ closedTwice' = TRUE
  /\ UNCHANGED <<nvim, latest, lastVis, cafBuf, cafPos, cafLeft, cafAway, rdBuf, rdVer, entryBuf, entryVer, db, dbStale, dbLoose, phantom>>
  /\ NoSpecChange

LooseDemotionCallbackRuns(b) ==
  /\ b \in dmLoose
  /\ \E keep \in BOOLEAN :
       LET s1 == [S EXCEPT !.dm = "nil", !.dmBuf = None,
                           !.dmLoose = (IF keep THEN @ ELSE @ \ {b}) \cup (IF dm \in Alive THEN {dmBuf} ELSE {})]
       IN SetS(Demote(s1, E, b))
  /\ UNCHANGED nvim
  /\ NoSpecChange

Next ==
  \/ \E r \in Ranges : YouStartSelecting(r)
  \/ \E r \in Ranges, p \in Pos : YouExtendSelection(r, p)
  \/ YouReleaseSelection
  \/ \E p \in Pos : YouEditSelection(p)
  \/ \E p \in Pos : YouMoveCursor(p)
  \/ YouEditAtCursor
  \/ YouEditByPlugin
  \/ YouEditElsewhere
  \/ \E b \in Bufs, p \in Pos : YouSwitchBuffer(b, p)
  \/ DebounceTimerFires
  \/ DebounceCallbackRuns
  \/ StaleDebounceCallbackRuns
  \/ LooseDebounceCallbackRuns
  \/ DemotionTimerFires
  \/ DemotionCallbackRuns
  \/ StaleDemotionCallbackRuns
  \/ \E b \in Bufs : LooseDemotionCallbackRuns(b)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules *)

\* No timer is running and no timer callback waits: the events have settled.
Settled == db = "nil" /\ dm = "nil" /\ ~dbStale /\ ~dmStale /\ ~dbLoose /\ dmLoose = {}
InFile == buf \in Files

(* Right after you release a selection in a file, Claude holds it, also when you made it *)
(* faster than the 100 ms debounce (issue #246).                                         *)
ReleaseSent == released => latest = hold

(* Claude only gets text you selected: never the text at the '<,'> marks after an *)
(* operator changed it.                                                          *)
NoPhantomSelection == ~phantom

(* Claude never gets a selection in the Claude terminal buffer. *)
NoTerminalSelection == latest = None \/ latest.buf # Term

(* Once events settle, a selection you released stays with Claude while the cursor *)
(* has not moved and its text is unchanged.                                        *)
HeldUntilMoved ==
  (Settled /\ InFile /\ mode = "n" /\ hold # None /\ ~holdLoose /\ hold.ver = ver[hold.buf]) => latest = hold

(* Once events settle, Claude holds a released selection only while the cursor has not *)
(* moved since you released it.                                                       *)
HeldEndsWhenMoved == (Settled /\ InFile /\ mode = "n" /\ hold = None) => latest \notin VisValues

(* Once events settle in a file, Claude's selection is in that file. *)
SameFile == (Settled /\ InFile /\ latest # None) => latest.buf = buf

(* Once events settle in a file, a cursor-only selection that Claude holds is where the *)
(* cursor is, and in visual mode Claude holds the live selection.                      *)
ClaudeSeesCursor ==
  Settled /\ InFile =>
    /\ mode = "v" => latest = Vis(buf, vsel, ver[buf])
    /\ (mode = "n" /\ latest \in CurValues /\ latest.buf = buf) => latest.at = cur

(* Once events settle, Claude holds no text that its buffer no longer has. *)
NoDeletedText == Settled => ~(latest \in VisValues /\ latest.ver # ver[latest.buf])

(* No timer handle is closed twice. *)
TimerClosedOnce == ~closedTwice
=============================================================================
