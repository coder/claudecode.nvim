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
(* queue its callback, and be cancelled before the callback runs. The       *)
(* listener on the buffer of a held selection queues its check the same way.*)
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
  MaxEdits,   \* edits per file buffer that change the text a selection can hold (YouEditSelection, YouEditAtCursor,
              \* YouEditByPlugin, YouEditOtherBuffer). Each one also moves the buffer's changedtick
  DelayBelowDebounce, \* environment: visual_demotion_delay_ms < debounce_ms, so a
                      \* demotion timer always fires before a later debounce timer
  WithTerminal,       \* environment: a Claude terminal buffer exists in Neovim (FALSE: terminal.provider
                      \* "none" or "external", Claude runs elsewhere)

  \* Code facts, see check.sh for the source lines each one reads.
  FlushOnVisualExit,     \* on_mode_changed calls flush_visual_selection when visual mode ends
  FlushSkipsOperator,    \* on_mode_changed records visual_entry; the flush returns when the entry has an edit that the
                         \* listener counted (an operator such as d consumed the selection)
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
  DemotionIgnoresTerminal, \* handle_selection_demotion returns in a Claude terminal and leaves
                           \* last_active_visual_selection alone (Condition 1)
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
  ReadRecordsTick,       \* the flush and the in-visual update record selection_tick
  ListensToSelectionBuffer, \* record_selection_read listens to the buffer of the selection it read, and a change of
                            \* that buffer schedules the check
  TerminalReportsHeldBuffer, \* the check, in the Claude terminal, sends the cursor of the selection's buffer when the
                             \* held text changed
  UpdateChecksHeldText,  \* update_selection runs that check in the Claude terminal too
  ListenerNotesVisualEdit, \* entering visual mode listens to the buffer, and an edit of it counts on the visual_entry
                           \* (note_visual_edit)
  VisualCheckSparesPluginEdit, \* the check that note_visual_edit schedules marks the entry consumed only when visual mode
                               \* has ended, so a plugin's edit that leaves the selection on the screen does not
  FlushIgnoresTick       \* neither on_mode_changed nor the flush reads a changedtick. FALSE models the code before #524, whose
                         \* flush returned when the changedtick moved since visual mode started

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
  ver,        \* per buffer: the version of the text that a selection can hold. An edit of the selected text advances it,
              \* a :write or an edit of another line does not (both move the changedtick all the same)
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
  entryDirty, \* visual_entry.consumed or visual_entry.unchecked_edits > 0: the listener counted an edit since visual mode started
  entryMoved, \* the changedtick of that buffer moved since visual mode started: any edit, or a :write. The code before #524
              \* compared the tick with the one recorded then. A tick only grows, so this bit is all the comparison reads
  db,         \* debounce_timer
  dbStale,    \* a callback of a cancelled debounce timer waits in the schedule queue
  dbLoose,    \* (only without DebounceIgnoresStale) a live debounce timer that the state lost
  dm,         \* demotion_timer
  dmBuf,      \* the buffer the demotion callback was scheduled for (current_buf)
  dmStale,    \* a callback of a cancelled demotion timer waits in the schedule queue
  dmLoose,    \* (only without DemotionIgnoresStale) buffers of live demotion timers the state lost
  chk,        \* check_soon of the listener on the buffer of the held selection: its callback waits in the schedule queue
  \* ghosts
  phantom,    \* Claude was sent text at the '<,'> marks that an edit changed after the selection
  closedTwice,\* timer:close() ran on a closed handle: Lua error "handle ... is already closing"
  hold,       \* the selection the user released with Esc, until the cursor moves; or None
  holdPos,    \* the cursor when it was released
  released    \* the last step was the release itself

nvim == <<buf, mode, cur, vsel, ver>>
plugin == <<latest, lastVis, cafBuf, cafPos, cafLeft, cafAway, rdBuf, rdVer, entryBuf, entryDirty, entryMoved, db, dbStale, dbLoose, dm,
            dmBuf, dmStale, dmLoose, chk, phantom, closedTwice>>
spec == <<hold, holdPos, released>>
vars == <<nvim, plugin, spec>>

TypeOK ==
  /\ buf \in Bufs /\ mode \in Modes /\ cur \in Pos
  /\ vsel \in Ranges \cup {None} /\ (mode = "v") = (vsel # None)
  /\ ver \in [Bufs -> 0..MaxEdits] /\ ver[Term] = 0
  /\ latest \in Values \cup {None}
  /\ lastVis \in Bufs \cup {None}
  /\ cafBuf \in Bufs \cup {None} /\ cafPos \in Pos /\ cafLeft \in BOOLEAN /\ cafAway \in Bufs \cup {None}
  /\ rdBuf \in Bufs \cup {None} /\ rdVer \in 0..MaxEdits
  /\ entryBuf \in Bufs \cup {None} /\ entryDirty \in BOOLEAN /\ entryMoved \in BOOLEAN
  /\ db \in TStates /\ dbStale \in BOOLEAN /\ dbLoose \in BOOLEAN
  /\ dm \in TStates /\ dmBuf \in Bufs \cup {None} /\ (dm = "nil") = (dmBuf = None)
  /\ dmStale \in BOOLEAN /\ dmLoose \subseteq Bufs /\ chk \in BOOLEAN
  /\ phantom \in BOOLEAN /\ closedTwice \in BOOLEAN
  /\ hold \in VisValues \cup {None} /\ holdPos \in Pos /\ released \in BOOLEAN

Init ==
  /\ buf = CHOOSE f \in Files : TRUE
  /\ mode = "n" /\ cur = P0 /\ vsel = None
  /\ ver = [b \in Bufs |-> 0]
  /\ latest = None /\ lastVis = None /\ cafBuf = None /\ cafPos = P0 /\ cafLeft = FALSE /\ cafAway = None /\ rdBuf = None /\ rdVer = 0 /\ entryBuf = None /\ entryDirty = FALSE /\ entryMoved = FALSE
  /\ db = "nil" /\ dbStale = FALSE /\ dbLoose = FALSE
  /\ dm = "nil" /\ dmBuf = None /\ dmStale = FALSE /\ dmLoose = {} /\ chk = FALSE
  /\ phantom = FALSE /\ closedTwice = FALSE
  /\ hold = None /\ holdPos = P0 /\ released = FALSE

-----------------------------------------------------------------------------
(* The plugin's state as a record, so that the code's functions chain as    *)
(* operators over it. E is the Neovim state the code reads (after the key). *)

S == [latest |-> latest, lastVis |-> lastVis, cafBuf |-> cafBuf, cafPos |-> cafPos, cafLeft |-> cafLeft, cafAway |-> cafAway, rdBuf |-> rdBuf, rdVer |-> rdVer, entryBuf |-> entryBuf,
      entryDirty |-> entryDirty, entryMoved |-> entryMoved, db |-> db, dbStale |-> dbStale, dbLoose |-> dbLoose, dm |-> dm, dmBuf |-> dmBuf,
      dmStale |-> dmStale, dmLoose |-> dmLoose, chk |-> chk, phantom |-> phantom, closedTwice |-> closedTwice]

SetS(s) ==
  /\ latest' = s.latest /\ lastVis' = s.lastVis /\ cafBuf' = s.cafBuf
  /\ cafPos' = IF s.cafBuf = None THEN P0 ELSE s.cafPos
  /\ cafLeft' = IF s.cafBuf = None THEN FALSE ELSE s.cafLeft
  /\ cafAway' = IF s.cafBuf = None THEN None ELSE s.cafAway
  /\ rdBuf' = s.rdBuf /\ rdVer' = IF s.rdBuf = None THEN 0 ELSE s.rdVer
  /\ entryBuf' = s.entryBuf
  /\ entryDirty' = (s.entryBuf # None /\ FlushSkipsOperator /\ s.entryDirty)  \* kept only while a guard reads it
  /\ entryMoved' = (s.entryBuf # None /\ ~FlushIgnoresTick /\ s.entryMoved)
  /\ db' = s.db /\ dbStale' = s.dbStale /\ dbLoose' = s.dbLoose
  /\ dm' = s.dm /\ dmBuf' = IF s.dm = "nil" THEN None ELSE s.dmBuf
  /\ dmStale' = s.dmStale /\ dmLoose' = s.dmLoose /\ chk' = s.chk
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

\* demote_if_selection_text_changed: the visual text in latest_selection was read in a buffer at another text version
\* than it has now. TextChanged is the check for the buffer you are in, HeldTextGone the check for the buffer of the
\* selection, whichever it is.
HeldTextGone(s, e) == s.rdBuf \in Bufs /\ s.latest \in VisValues /\ s.rdVer # e.ver[s.rdBuf]
TextChanged(s, e) == s.rdBuf = e.buf /\ HeldTextGone(s, e)

\* In the Claude terminal, which keeps a held selection of another buffer and does not update it, the check sends the
\* cursor of the selection's buffer: where its window has the cursor, else where the selection was released.
TerminalChanged(s, e) == e.buf = Term /\ s.rdBuf \in Files /\ HeldTextGone(s, e)
ReportHeldBuffer(s) == Publish(ClearHeld(s), Cur(s.rdBuf, IF s.cafBuf = s.rdBuf THEN s.cafPos ELSE P0))

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
  CASE here = Term /\ UpdateSkipsTerminal ->
         IF UpdateChecksHeldText /\ TerminalReportsHeldBuffer /\ TerminalChanged(s, e)
         THEN ReportHeldBuffer(CancelDemotion(s))
         ELSE CancelDemotion(s)
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
  CASE e.buf = Term -> IF DemotionIgnoresTerminal THEN s ELSE clearVis(s)  \* Condition 1
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
    [] s.entryBuf = here /\ ((FlushSkipsOperator /\ s.entryDirty) \/ (~FlushIgnoresTick /\ s.entryMoved)) ->
         IF ~FlushSkipReports THEN s
         ELSE IF s.latest \in VisValues THEN Update(ClearHeld(s), e)
         ELSE ClearHeld(s)
    [] OTHER -> Publish(CancelDemotion(rec), sel)

(* selection.lua on_mode_changed, then the debounce. Entering visual mode makes the visual_entry, leaving it flushes and *)
(* then forgets the entry.                                                                                               *)
OnModeChanged(s, e, entering, leaving) ==
  LET entered == [s EXCEPT !.entryBuf = e.buf, !.entryDirty = FALSE, !.entryMoved = FALSE]
      left == IF FlushOnVisualExit THEN Flush(s, e) ELSE s
      s1 == CASE entering -> IF e.buf = Term \/ ~EntryClearsHeld THEN entered ELSE ClearHeld(entered)
              [] leaving -> [left EXCEPT !.entryBuf = None]
              [] OTHER -> s
  IN DebounceUpdate(s1)

E2(b, m, c, v, mk, vr) == [buf |-> b, mode |-> m, cur |-> c, vsel |-> v, marks |-> mk, ver |-> vr]

\* The changedtick of buffer b moved: an edit, or a :write. The visual_entry of b notes that it moved.
TickMoved(s, b) == IF s.entryBuf = b THEN [s EXCEPT !.entryMoved = TRUE] ELSE s

\* An edit of buffer b reaches the listener (on_lines): note_visual_edit counts it on the visual_entry of b.
EntryEdited(s, b) == IF s.entryBuf = b /\ ListenerNotesVisualEdit THEN [s EXCEPT !.entryDirty = TRUE] ELSE s

\* A plugin's edit in visual mode: the listener counts it, and the model runs the check in the same step. The code runs it
\* from vim.schedule and from a vim.on_key listener, whichever comes first, so it comes before the flush of the next Esc
\* (before #540 only the schedule ran it, and a key that came first reached the flush with an unchecked edit: a mapping
\* that edits and presses Esc in one typeahead, a key during a callback, an autocmd edit at a mode change). Visual mode
\* is still on at the check, so the entry is not consumed, unless the code takes every counted edit for an operator's.
PluginEditedInVisual(s, b) ==
  TickMoved(IF VisualCheckSparesPluginEdit THEN s ELSE EntryEdited(s, b), b)

\* reconcile_held_selection (on_cursor_moved, on_text_changed): changed text makes the plugin report the cursor at
\* once. A cursor that left the flushed position is reported at once (it is final at CursorMoved), another buffer is noted. At CursorMoved and TextChanged the
\* cursor is compared, at BufEnter it is not (Neovim restores it after the event). Entering the Claude terminal
\* keeps the hold and cancels the pending demotion.
\* termKnown: is_claude_terminal_buffer(current buffer) at this event. A new Claude terminal is not registered when
\* BufEnter fires, so then it may be FALSE: the buffer is noted in cafAway and decided at the next event.
Reconcile(s, e, compareCursor, termKnown) ==
  IF TextChangeReports /\ TextChanged(s, e) THEN Update(ClearHeld(s), e)
  ELSE IF TerminalReportsHeldBuffer /\ termKnown /\ TerminalChanged(s, e) THEN ReportHeldBuffer(s)
  ELSE IF s.cafBuf = None \/ s.cafLeft THEN s
  ELSE LET awayGone == LeaveNoted /\ s.cafAway # None /\ s.cafAway # e.buf
       IN IF awayGone /\ s.cafAway # Term THEN [s EXCEPT !.cafLeft = TRUE]
          ELSE LET s1 == IF awayGone THEN [s EXCEPT !.cafAway = None] ELSE s
               IN IF e.buf = Term /\ termKnown THEN CancelDemotion([s1 EXCEPT !.cafAway = None])
                  ELSE IF LeaveNoted /\ s1.cafBuf # e.buf THEN [s1 EXCEPT !.cafAway = e.buf]
                  ELSE IF MoveReports /\ compareCursor /\ ~Unmoved(s1, e) THEN Update(ClearHeld(s1), e)
                  ELSE s1

\* The listener on the buffer b of the selection Claude holds (watch_selection_buffer): on_lines runs while b changes,
\* and only queues the check with vim.schedule (check_soon), which does not touch the buffer in the callback. It
\* queues nothing when b does not hold the selection.
OnOtherBufferChanged(s, b) ==
  IF ListensToSelectionBuffer /\ s.rdBuf = b /\ s.latest \in VisValues THEN [s EXCEPT !.chk = TRUE] ELSE s

\* The queued callback: demote_if_selection_text_changed in whatever state the user is in when it runs. For the buffer
\* you are in it ends the hold, as TextChanged does. In the Claude terminal, which does not update the selection, it
\* sends the cursor of the selection's buffer: where its window has the cursor, else where the selection was released.
\* In another file it does nothing: the debounce replaces the selection there.
\* A scheduled callback runs after the command that made a new Claude terminal returned, so the plugin knows the
\* terminal then, unlike at the BufEnter that the command fires.
ListenerCheck(s, e) ==
  IF TextChanged(s, e) THEN Update(ClearHeld(s), e)
  ELSE IF TerminalReportsHeldBuffer /\ TerminalChanged(s, e) THEN ReportHeldBuffer(s)
  ELSE s

\* The two handlers that call it. A key that edits the cursor line (x) fires CursorMoved, then TextChanged.
OnCursor(s, e, compareCursor, termKnown) == IF ReconcileOnCursorMoved THEN Reconcile(s, e, compareCursor, termKnown) ELSE s
OnText(s, e) == IF ReconcileOnTextChanged THEN Reconcile(s, e, TRUE, TRUE) ELSE s

NoSpecChange == UNCHANGED <<hold, holdPos>> /\ released' = FALSE
DropHold == hold' = None /\ holdPos' = P0 /\ released' = FALSE

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
     THEN hold' = Vis(buf, vsel, ver[buf]) /\ holdPos' = cur /\ released' = TRUE
     ELSE NoSpecChange

(* d, c, x, > or another operator on the selection: the text changes (the listener sees *)
(* the edit with the mode already normal, then ModeChanged fires) and the cursor lands   *)
(* on p. CursorMoved and TextChanged fire when Neovim waits for the next key, so a       *)
(* mapping, a macro or typeahead runs the next key first. The step leaves them out: it   *)
(* is the case in which they have not fired yet.                                         *)
YouEditSelection(p) ==
  /\ buf \in Files /\ mode = "v" /\ ver[buf] < MaxEdits
  /\ LET vr == [ver EXCEPT ![buf] = @ + 1]
     IN /\ ver' = vr
        /\ SetS(DebounceUpdate(OnModeChanged(TickMoved(EntryEdited(S, buf), buf),
                                              E2(buf, "n", p, None, [at |-> vsel, ver |-> ver[buf]], vr), FALSE, TRUE)))
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

(* A plugin edits another line while you select, and the selection stays on the screen with the *)
(* text it had: the changedtick moves, and the listener counts the edit. No TextChanged and no   *)
(* CursorMoved fire in visual mode. An edit whose check has not run when the next key arrives   *)
(* would reach the flush unchecked: the code checks it at the next key too (see SKILL.md).       *)
YouEditByPluginInVisual ==
  /\ buf \in Files /\ mode = "v"
  /\ SetS(PluginEditedInVisual(S, buf))
  /\ UNCHANGED nvim
  /\ NoSpecChange

(* :write in visual mode: it moves the changedtick of a modified buffer and fires no on_lines. *)
YouWriteInVisual ==
  /\ buf \in Files /\ mode = "v"
  /\ SetS(TickMoved(S, buf))
  /\ UNCHANGED nvim
  /\ NoSpecChange

(* A plugin edits, or Neovim reloads, a file that is not the current buffer, and the held *)
(* text with it: no TextChanged and no BufEnter fire. The listener on that buffer queues a *)
(* check (ListenerCheckRuns), which runs later, after any other step. *)
YouEditOtherBuffer(b) ==
  /\ mode = "n" /\ b \in Files /\ b # buf /\ ver[b] < MaxEdits
  /\ ver' = [ver EXCEPT ![b] = @ + 1]
  /\ SetS(OnOtherBufferChanged(S, b))
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
(* cursor where it was, Claude keeps it.                                         *)
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
  /\ IF b = Term \/ (buf = Term /\ hold # None /\ hold.buf = b /\ p = holdPos)
     THEN NoSpecChange
     ELSE DropHold

-----------------------------------------------------------------------------
(* The timers. uv fires a timer; schedule_wrap queues its callback; the    *)
(* callback runs later on the main loop.                                   *)

(* The debounce uv timer fires. With the default delays, a pending demotion fires first. *)
DebounceTimerFires ==
  /\ db = "armed"
  /\ DelayBelowDebounce => dm \notin Alive
  /\ db' = "queued"
  /\ UNCHANGED <<nvim, latest, lastVis, cafBuf, cafPos, cafLeft, cafAway, rdBuf, rdVer, entryBuf, entryDirty, entryMoved, dbStale, dbLoose, dm, dmBuf, dmStale,
                 dmLoose, chk, phantom, closedTwice>>
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
  /\ UNCHANGED <<nvim, latest, lastVis, cafBuf, cafPos, cafLeft, cafAway, rdBuf, rdVer, entryBuf, entryDirty, entryMoved, dm, dmBuf, dmStale, dmLoose, chk, phantom>>
  /\ NoSpecChange

(* Without the identity check: a live debounce timer the field lost fires and runs in full. *)
LooseDebounceCallbackRuns ==
  /\ dbLoose
  /\ \E keep \in BOOLEAN :  \* other lost timers can still be live
       SetS(Update([S EXCEPT !.db = "nil", !.dbLoose = keep \/ db \in Alive], E))
  /\ UNCHANGED nvim
  /\ NoSpecChange

(* check_soon's callback of the listener runs: the check, then nothing is queued. *)
ListenerCheckRuns ==
  /\ chk
  /\ SetS(ListenerCheck([S EXCEPT !.chk = FALSE], E))
  /\ UNCHANGED nvim
  /\ NoSpecChange

DemotionTimerFires ==
  /\ dm = "armed"
  /\ dm' = "queued"
  /\ UNCHANGED <<nvim, latest, lastVis, cafBuf, cafPos, cafLeft, cafAway, rdBuf, rdVer, entryBuf, entryDirty, entryMoved, db, dbStale, dbLoose, dmBuf, dmStale,
                 dmLoose, chk, phantom, closedTwice>>
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
  /\ UNCHANGED <<nvim, latest, lastVis, cafBuf, cafPos, cafLeft, cafAway, rdBuf, rdVer, entryBuf, entryDirty, entryMoved, db, dbStale, dbLoose, chk, phantom>>
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
  \/ YouEditByPluginInVisual
  \/ YouWriteInVisual
  \/ \E b \in Files : YouEditOtherBuffer(b)
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
  \/ ListenerCheckRuns

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules *)

\* No timer is running and no timer callback waits: the events have settled.
Settled == db = "nil" /\ dm = "nil" /\ ~dbStale /\ ~dmStale /\ ~dbLoose /\ dmLoose = {} /\ ~chk
InFile == buf \in Files

(* Right after you release a selection in a file, Claude holds it, also when you made it *)
(* faster than the 100 ms debounce (issue #246).                                         *)
ReleaseSent == released => latest = hold

(* Claude only gets text you selected: never the text at the '<,'> marks after an *)
(* operator changed it.                                                          *)
NoPhantomSelection == ~phantom

(* Claude never gets a selection in the Claude terminal buffer. *)
NoTerminalSelection == latest = None \/ latest.buf # Term

(* Once events settle in a file, a selection you released stays with Claude while the *)
(* cursor has not moved and its text is unchanged.                                    *)
HeldUntilMoved ==
  (Settled /\ InFile /\ mode = "n" /\ hold # None /\ hold.ver = ver[hold.buf]) => latest = hold

(* Once events settle in the Claude terminal, Claude still holds the selection you released *)
(* while its text is unchanged: going there to type the question must not lose it (#246).   *)
HeldInTerminal ==
  (Settled /\ buf = Term /\ hold # None /\ hold.ver = ver[hold.buf]) => latest = hold

(* Once events settle in a file, Claude holds a released selection only while the cursor *)
(* has not moved since you released it.                                                 *)
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
