------------------------- MODULE TerminalLifecycle -------------------------
(***************************************************************************)
(* The Claude terminal in claudecode.nvim: the native and snacks providers *)
(* and the provider choice in lua/claudecode/terminal.lua.                  *)
(*                                                                          *)
(* The plugin must run at most one Claude, also after a reload of its       *)
(* modules, stop it on :ClaudeCodeClose,                                     *)
(* never reuse a terminal it is closing, show a running Claude when you     *)
(* open it, keep Claude running when you hide it, hide without an error,    *)
(* clean up after a failed start, and close only its own window when       *)
(* Claude exits.                                                            *)
(*                                                                          *)
(* One step is one run of Neovim's main loop: a command, a job exit (its    *)
(* TermClose autocmds run in the same step), one vim.schedule callback, or *)
(* one autocmd that calls the plugin while a start runs. vim.wait in a      *)
(* close pumps the loop, so callbacks, job exits and scheduled opens can    *)
(* run inside it (pc.op = "waiting"); typed commands cannot.                *)
(*                                                                          *)
(* Code facts (BOOLEAN constants) are read from the source by check.sh:     *)
(* TRUE means the guard is in the code, FALSE models the code without it.   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
  Terms,             \* terminal buffers the plugin can start (model values); each start takes a fresh one
  Providers,         \* terminal.provider values setup can get: subset of {"native", "snacks", "auto"}
  LoadableAtStart,   \* whether require("snacks") succeeds at setup: subset of BOOLEAN

  \* Environment switches, not code facts. check.sh turns all of them on for the main run.
  Reloads,           \* the plugin's modules reload once (package.loaded cleared, setup runs again)
  ProviderChanges,   \* that setup can pick another provider (a config edit, or auto resolving differently)
  AutocmdReenters,   \* a BufEnter or TermOpen autocmd calls open or a toggle while a start runs
  OpenBeforeCleanup, \* an open can run while plugin callbacks are queued (FALSE: the queue drains first)
  Swaps,             \* you show another buffer in Claude's window (:e file, :b other)
  Wipes,             \* you wipe Claude's buffer (:bwipeout!)
  OnlyWindow,        \* you make Claude's window the only window (:only)

  \* Code facts, see check.sh for the source lines each one reads.
  NativeMarkBeforeTermopen,      \* native.lua open_terminal marks the buffer before termopen
  OwnedUnstartedIsNotEnded,      \* owned.lua job_ended: a buffer whose job has not started has not ended
  OwnedLiveNeedsMark,            \* owned.lua is_live: a buffer is live only when it carries the mark
  OwnedLiveSkipsEndedJob,        \* owned.lua is_live: a buffer is live only when its job has not ended
  NativeAdoptsHiddenTerminal,    \* native.lua adopt_existing_terminal adopts a terminal that no window shows
  NativeShowsAdoptedHidden,      \* native.lua focus_adopted shows an adopted terminal that no window shows
  NativeExitClearsMark,          \* native.lua on_exit clears the mark before forget_exited_job
  NativeAdoptedExitHandled,      \* native.lua adopt_existing_terminal adds a TermClose handler that forgets
  NativeExitForgetsOwnJobOnly,   \* native.lua forget_exited_job returns for another job's exit
  NativeExitKeepsLastWindow,     \* native.lua forget_exited_job skips the last window
  NativeExitChecksWindowBuffer,  \* native.lua forget_exited_job closes the window only if it shows the terminal
  NativeEntriesForgetEndedJob,   \* native.lua open, simple_toggle, focus_toggle run forget_ended_terminal first
  NativeRescansSwappedWindow,    \* native.lua is_valid scans the windows when the tracked one shows another buffer
  NativeCloseAdopts,             \* native.lua close_terminal adopts a terminal first
  NativeCloseForgetsFirst,       \* native.lua close_terminal clears its state before vim.wait
  NativeCloseClearsMark,         \* native.lua close_terminal clears the mark before vim.wait
  NativeKeepsHiddenJob,          \* native.lua open_terminal sets bufhidden=hide
  NativeHideKeepsLastWindow,     \* native.lua hide_terminal skips (or pcalls) closing the last window
  NativeFailCleansUp,            \* native.lua open_terminal closes the split, deletes the buffer, clears state
  NativeStartSurvivesClosedSplit, \* native.lua open_terminal goes on, with Claude hidden, when an autocmd of the start closed its split
  NativeOpenSkipsDuringStart,    \* native.lua open_terminal returns while a start runs: an entry that an autocmd of the start calls starts none
  NativeRunsDeferredClose,       \* native.lua open_terminal runs the close that an autocmd of the start asked for, when the start returns
  NativeStopsSnacksClaude,       \* native.lua stops the snacks provider's Claude before a start and in close
  SnacksOpenSkipsDuringStart,    \* snacks.lua M.open returns while its own Snacks.terminal.open runs
  SnacksMarksStartedTerminal,    \* snacks.lua M.open marks the buffer of a started terminal
  SnacksEntriesAdopt,            \* snacks.lua open, simple_toggle, focus_toggle adopt a listed marked instance
  SnacksEntriesForgetEndedJob,   \* snacks.lua adopt_existing_terminal (first in each entry) forgets a tracked terminal whose job ended (auto_close)
  SnacksCloseAdopts,             \* snacks.lua M.close adopts a listed marked instance first
  SnacksExitForgets,             \* snacks.lua TermClose handler (auto_close) forgets the instance at once
  SnacksForgetChecksInstance,    \* snacks.lua forget() clears `terminal` only for its own instance
  SnacksCloseForgetsFirst,       \* snacks.lua M.close sets terminal = nil before vim.wait
  SnacksCloseClearsMark,         \* snacks.lua M.close clears the mark before the wait for the exec and jobstop
  SnacksHideKeepsLastWindow,     \* snacks.lua cc_hide pcalls nvim_win_close
  SnacksFailCleansUp,            \* snacks.lua M.open closes the window Snacks showed for a failed start
  SnacksStopsNativeClaude,       \* snacks.lua stops the native provider's Claude before a start and in close
  OwnedStopOtherStops,           \* owned.lua stop_other stops every marked live buffer of the other provider (stop_buffer: job, wait, delete)
  SnacksAvailabilityCached       \* snacks.lua reads require("snacks") once; terminal.lua caches the module

None == "none"
Gens == {"cur", "old"}
Items == [k : {"exit", "adopted", "snacksClose"}, t : Terms, g : Gens]
IdlePc == [op |-> "idle", t |-> None, p |-> None, re |-> FALSE, cl |-> FALSE]

VARIABLES
  cfg,       \* setup's terminal options: provider, auto_close, and your 'hidden' option
  loadable,  \* require("snacks") succeeds now
  seen,      \* what snacks.lua read from require("snacks") when the current module copy loaded it
  reloaded,  \* the one modeled reload happened
  pc,        \* the Lua call in progress: idle, a start ("begin", "split", "started"), or a close in vim.wait; cl: a close was asked for during the start
  asked,     \* ghost: the Claudes that ran when the :ClaudeCodeClose in progress began
  closed,    \* ghost: terminals a close began on
  job,       \* per terminal: "none" (before termopen), "running", "exited", "failed"
  by,        \* per terminal: the provider that started it
  gen,       \* per terminal: the module copy that started it ("old" after the reload)
  buf,       \* per terminal: its buffer is valid
  win,       \* per terminal: a window shows its buffer
  swapped,   \* per terminal: native.lua's winid shows another buffer now
  mark,      \* per terminal: b:claudecode_native_terminal
  adoptedBy, \* per terminal: the copy whose ClaudeCodeNativeAdopted TermClose handler it has
  others,    \* a window that shows no Claude terminal exists
  ntrack,    \* native.lua bufnr/jobid in the current module copy
  oldTrack,  \* native.lua bufnr/jobid in the copy from before the reload
  oldWin,    \* that copy's winid still shows oldTrack's buffer
  strack,    \* snacks.lua `terminal` in the current module copy
  queue,     \* scheduled callbacks not run yet (a set: the model does not keep their order)
  bad        \* ghost: marks of rule breaks, see the rules at the end

vars == <<cfg, loadable, seen, reloaded, pc, asked, closed, job, by, gen, buf, win, swapped, mark, adoptedBy, others,
          ntrack, oldTrack, oldWin, strack, queue, bad>>

(* The state one terminal operation touches, as a record, so that a step   *)
(* that runs a whole open (an autocmd, a scheduled open) can chain them.   *)
W == [job |-> job, by |-> by, gen |-> gen, buf |-> buf, win |-> win, swapped |-> swapped, mark |-> mark,
      adoptedBy |-> adoptedBy, others |-> others, ntrack |-> ntrack, oldTrack |-> oldTrack, oldWin |-> oldWin,
      strack |-> strack, queue |-> queue, bad |-> bad]

SetW(w) ==
  /\ job' = w.job /\ by' = w.by /\ gen' = w.gen /\ buf' = w.buf /\ win' = w.win /\ swapped' = w.swapped
  /\ mark' = w.mark /\ adoptedBy' = w.adoptedBy /\ others' = w.others /\ ntrack' = w.ntrack
  /\ oldTrack' = w.oldTrack /\ oldWin' = w.oldWin /\ strack' = w.strack /\ queue' = w.queue /\ bad' = w.bad

Flag(w, f) == [w EXCEPT !.bad = @ \cup {f}]

(* terminal.lua get_provider. "snacks" and "auto" both fall back to native  *)
(* when snacks.lua reports Snacks unavailable ("snacks" also warns).        *)
SnacksUp == IF SnacksAvailabilityCached THEN seen ELSE loadable
Prov == IF cfg.provider = "native" \/ ~SnacksUp THEN "native" ELSE "snacks"

(* native.lua is_last_window: the only window of the only tab page. *)
IsLast(w, t) == w.win[t] /\ ~w.others /\ \A u \in Terms \ {t} : ~w.win[u]

(* The window that shows t closes. The old copy's winid then names a closed window. *)
NoWin(w, t) == [w EXCEPT !.win[t] = FALSE, !.oldWin = IF w.oldTrack = t THEN FALSE ELSE @]

(* snacks.lua setup_terminal_events forget(), in the copy that registered it. *)
SnacksForget(w, t) ==
  IF w.gen[t] # "cur" THEN w
  ELSE [w EXCEPT !.strack = IF @ = t \/ ~SnacksForgetChecksInstance THEN None ELSE @]

(* The job of t ends. Its TermClose autocmds run in this step: snacks'      *)
(* handler (auto_close only) forgets and schedules term_instance:close, and *)
(* native's ClaudeCodeNativeAdopted handler schedules forget_exited_job.    *)
(* native's termopen on_exit only calls vim.schedule, so its own event      *)
(* changes no state, and the model queues its scheduled callback here.      *)
Exits(w, t) ==
  LET w1 == [w EXCEPT !.job[t] = "exited"]
  IN IF w.by[t] = "snacks"
     THEN IF cfg.autoClose
          THEN LET w2 == IF SnacksExitForgets THEN SnacksForget(w1, t) ELSE w1
               IN [w2 EXCEPT !.queue = @ \cup {[k |-> "snacksClose", t |-> t, g |-> w.gen[t]]}]
          ELSE w1
     ELSE [w1 EXCEPT !.queue = @ \cup {[k |-> "exit", t |-> t, g |-> w.gen[t]]}
                                 \cup IF w.adoptedBy[t] = None THEN {}
                                      ELSE {[k |-> "adopted", t |-> t, g |-> w.adoptedBy[t]]}]

(* Buffer t is wiped (nvim_buf_delete with force, :bwipeout!, an unload).   *)
(* Neovim closes its windows; the last window stays and shows another       *)
(* buffer. A running job ends. snacks' BufWipeout handler forgets.          *)
Wiped(w, t) ==
  LET w1 == IF IsLast(w, t) THEN [NoWin(w, t) EXCEPT !.others = TRUE] ELSE NoWin(w, t)
      w2 == [w1 EXCEPT !.buf[t] = FALSE]
      w3 == IF w.job[t] = "running" THEN Exits(w2, t) ELSE w2
  IN IF w.by[t] = "snacks" THEN SnacksForget(w3, t) ELSE w3

(* nvim_win_close on t's window (a hide, :only). bufhidden=hide keeps the  *)
(* buffer and its job: native sets it (NativeKeepsHiddenJob) and a snacks   *)
(* scratch buffer has it. Otherwise, under 'nohidden', Neovim unloads the   *)
(* buffer and the job ends.                                                 *)
WinClosed(w, t) ==
  IF w.by[t] = "snacks" \/ NativeKeepsHiddenJob \/ cfg.hidden \/ w.job[t] # "running" THEN NoWin(w, t)
  ELSE Wiped(Flag(NoWin(w, t), "hideKilled"), t)

(* native.lua hide_terminal / snacks.lua cc_hide (a split). nvim_win_close *)
(* raises E444 for the last window unless a guard skips it.               *)
Hide(w, t, guarded) ==
  IF IsLast(w, t) THEN IF guarded THEN w ELSE Flag(w, "hideError")
  ELSE WinClosed(w, t)

(* After an open, focus or show: you see t, and Claude runs in it. A snacks *)
(* terminal with auto_close = false keeps its exited Claude by design       *)
(* (terminal/README.md: snacks reuses the instance while buf_valid()).     *)
Shown(w, t) ==
  IF w.win[t] /\ (w.job[t] \in {"none", "running"} \/ (w.by[t] = "snacks" /\ ~cfg.autoClose)) THEN w
  ELSE Flag(w, "badOpen")

(* native.lua forget_exited_job in module copy g, for the job of t. *)
NativeForget(w, t, g) ==
  LET u == IF g = "cur" THEN w.ntrack ELSE w.oldTrack
  IN IF u = None \/ (NativeExitForgetsOwnJobOnly /\ u # t) THEN w
     ELSE LET own == IF g = "cur" THEN w.win[u] ELSE w.oldWin    \* the copy's winid shows u's buffer
              other == g = "cur" /\ w.swapped[u]                 \* the copy's winid shows another buffer
              w1 == IF g = "cur" THEN [w EXCEPT !.ntrack = None] ELSE [w EXCEPT !.oldTrack = None, !.oldWin = FALSE]
          IN IF ~cfg.autoClose THEN w1
             ELSE IF own
                  THEN IF ~IsLast(w1, u) THEN NoWin(w1, u)
                       ELSE IF NativeExitKeepsLastWindow THEN w1 ELSE Flag(w1, "exitError")
                  ELSE IF other /\ ~NativeExitChecksWindowBuffer
                       THEN Flag([w1 EXCEPT !.swapped[u] = FALSE], "exitClosedOther")
                       ELSE w1

(* owned.lua job_ended: before termopen (or after it failed) the channel is 0. jobstop makes jobpid raise at      *)
(* once, so a terminal that a close began on counts as ended while the close waits.                              *)
JobEnded(w, b) ==
  \/ b \in closed
  \/ IF w.job[b] \in {"none", "failed"} THEN ~OwnedUnstartedIsNotEnded ELSE w.job[b] # "running"

(* owned.lua is_live: a buffer that carries the provider's mark and whose job has not ended. *)
IsLive(w, b, p) ==
  /\ ((w.by[b] = p /\ w.mark[b]) \/ ~OwnedLiveNeedsMark)
  /\ (~JobEnded(w, b) \/ ~OwnedLiveSkipsEndedJob)

(* native.lua adopt_existing_terminal: a live marked buffer, whether or not a window shows it. *)
Adoptable(w) ==
  {b \in Terms : /\ w.by[b] # None /\ w.buf[b]
                 /\ (w.win[b] \/ NativeAdoptsHiddenTerminal)
                 /\ IsLive(w, b, "native")}

Adopt(w, b) ==
  [w EXCEPT !.ntrack = b, !.swapped[b] = FALSE, !.adoptedBy[b] = IF NativeAdoptedExitHandled THEN "cur" ELSE @]

(* snacks.lua adopt_existing_terminal: a live marked buffer (the mark and a job that has not ended). *)
SnacksAdoptable(w) ==
  {b \in Terms : w.by[b] = "snacks" /\ w.buf[b] /\ IsLive(w, b, "snacks")}

SnacksAdopt(w, b) == [w EXCEPT !.strack = b]

(* snacks.lua forget_ended_terminal, the first step of adopt_existing_terminal: with auto_close, a tracked terminal   *)
(* whose job ended is forgotten before a TermClose handler or the scheduled close has run.                           *)
SnacksForgetEnded(w) ==
  IF SnacksEntriesForgetEndedJob /\ cfg.autoClose /\ w.strack # None /\ w.buf[w.strack] /\ JobEnded(w, w.strack)
  THEN [w EXCEPT !.strack = None]
  ELSE w

Out(w, s) == [w |-> w, start |-> s]

(* The live terminals that the provider q marked. *)
Foreign(w, q) == {b \in Terms : w.by[b] = q /\ w.buf[b] /\ w.mark[b] /\ ~JobEnded(w, b)}

RECURSIVE StopAll(_, _)
(* owned.lua stop_other: the other provider closes its Claude, or the marked buffer is stopped and deleted. *)
StopAll(w, S) == IF S = {} THEN w ELSE LET u == CHOOSE x \in S : TRUE IN StopAll(Wiped(w, u), S \ {u})

(* native.lua M.open (kind "open"; terminal.lua ensure_visible calls it    *)
(* too) and M.focus_toggle (kind "toggle": hide when you are in it, focus  *)
(* when you are not; it covers M.simple_toggle). start = TRUE: the entry   *)
(* calls open_terminal next.                                                *)

(* A start of native is in progress: open_terminal runs start_terminal. Its vsplit and the creation of its buffer ("begin") *)
(* run the autocmds of the user's before the buffer has a mark, and nothing is tracked until the start returns.            *)
NativeStarting == pc.op \in {"begin", "split", "started"} /\ pc.p = "native"

(* A tracked terminal with a valid buffer. is_valid scans the windows when the tracked one shows another buffer. *)
NativeTracked(w, t, kind) ==
  IF kind = "open"
  THEN IF w.win[t] \/ (w.swapped[t] /\ ~NativeRescansSwappedWindow)
       THEN {Out(Shown(w, t), FALSE)}                                                    \* winid valid: focus_terminal
       ELSE {Out(Shown([w EXCEPT !.win[t] = TRUE, !.swapped[t] = FALSE], t), FALSE)}    \* show_hidden_terminal
  ELSE LET v == [w EXCEPT !.swapped[t] = FALSE]                                         \* is_terminal_visible scans windows
       IN IF w.win[t]
          THEN {Out(Hide(v, t, NativeHideKeepsLastWindow), FALSE), Out(Shown(v, t), FALSE)}
          ELSE {Out(Shown([v EXCEPT !.win[t] = TRUE], t), FALSE)}

(* After adoption: focus_adopted (open, simple_toggle) or the focus_toggle branches. A hidden terminal is shown. *)
NativeAdopted(w, b, kind) ==
  LET a == Adopt(w, b)
  IN IF w.win[b]
     THEN IF kind = "open" THEN {Out(Shown(a, b), FALSE)}
          ELSE {Out(Shown(a, b), FALSE), Out(Hide(a, b, NativeHideKeepsLastWindow), FALSE)}
     ELSE IF NativeShowsAdoptedHidden THEN {Out(Shown([a EXCEPT !.win[b] = TRUE], b), FALSE)}
          ELSE {Out(Shown(a, b), FALSE)}

NativeEntry(w0, kind) ==
  LET t0 == w0.ntrack
      \* forget_ended_terminal: the cleanup that on_exit schedules, run now for a terminal whose job already ended
      w == IF NativeEntriesForgetEndedJob /\ t0 # None /\ w0.buf[t0] /\ w0.job[t0] = "exited"
           THEN NativeForget(w0, t0, "cur") ELSE w0
      t == w.ntrack
  IN IF t # None /\ w.buf[t]
     THEN NativeTracked(w, t, kind)
     ELSE LET wn == [w EXCEPT !.ntrack = None]                        \* is_valid() forgets an invalid buffer
              ad == Adoptable(wn)
          IN IF ad = {}
             THEN IF NativeOpenSkipsDuringStart /\ NativeStarting THEN {Out(wn, FALSE)}
                  ELSE {Out(IF NativeStopsSnacksClaude /\ OwnedStopOtherStops THEN StopAll(wn, Foreign(wn, "snacks")) ELSE wn, TRUE)}
             ELSE UNION {NativeAdopted(wn, b, kind) : b \in ad}

(* A start of snacks is in progress: Snacks.terminal.open runs and `terminal` is not set yet. *)
SnacksStarting == pc.op \in {"split", "started"} /\ pc.p = "snacks"

SnacksTracked(w, t, kind) ==
  IF kind = "open" \/ ~w.win[t]
  THEN {Out(Shown([w EXCEPT !.win[t] = TRUE], t), FALSE)}
  ELSE {Out(Hide(w, t, SnacksHideKeepsLastWindow), FALSE), Out(Shown(w, t), FALSE)}

(* snacks.lua M.open (cc_show), M.focus_toggle and M.simple_toggle. *)
SnacksEntry(w0, kind) ==
  LET w == SnacksForgetEnded(w0)
      t0 == w.strack
      ad == IF SnacksEntriesAdopt /\ ~(t0 # None /\ w.buf[t0]) THEN SnacksAdoptable(w) ELSE {}
  IN IF t0 # None /\ w.buf[t0] THEN SnacksTracked(w, t0, kind)
     ELSE IF ad # {} THEN UNION {SnacksTracked(SnacksAdopt(w, b), b, kind) : b \in ad}
     ELSE IF SnacksOpenSkipsDuringStart /\ SnacksStarting THEN {Out(w, FALSE)}
     ELSE {Out(IF SnacksStopsNativeClaude /\ OwnedStopOtherStops THEN StopAll(w, Foreign(w, "native")) ELSE w, TRUE)}

Entry(w, p, kind) == IF p = "native" THEN NativeEntry(w, kind) ELSE SnacksEntry(w, kind)

HasFresh(w) == \E t \in Terms : w.by[t] = None
FreshT(w) == CHOOSE t \in Terms : w.by[t] = None

(* A start up to termopen. native.lua open_terminal: vsplit, a new buffer, *)
(* the mark, nvim_win_set_buf. snacks: Snacks.terminal.open shows its      *)
(* window and scratch buffer before it calls termopen.                     *)
Split(w, p, t) ==
  [w EXCEPT !.by[t] = p, !.gen[t] = "cur", !.buf[t] = TRUE, !.win[t] = TRUE,
            !.mark[t] = (p = "native" /\ NativeMarkBeforeTermopen)]

Started(w, t) == [w EXCEPT !.job[t] = "running"]

(* The start returns: native sets bufnr/jobid/winid (and the mark, in a    *)
(* model where it comes after termopen); snacks sets `terminal`. A toggle  *)
(* of an autocmd of the start can have hidden native's new split (the only *)
(* step that closes it while a start runs). open_terminal then reads a     *)
(* window that is gone, which raises, unless NativeStartSurvivesClosedSplit. *)
(* With it, Claude runs hidden and tracked.                                 *)
Finish(w, p, t) ==
  LET n == [w EXCEPT !.ntrack = t, !.swapped[t] = FALSE, !.mark[t] = TRUE]
  IN IF p = "native"
     THEN IF w.win[t] THEN Shown(n, t)
          ELSE IF NativeStartSurvivesClosedSplit THEN n ELSE Flag(n, "hideError")
     ELSE Shown([w EXCEPT !.strack = t, !.mark[t] = SnacksMarksStartedTerminal], t)

(* termopen raised. native: close the split, delete the buffer,           *)
(* cleanup_state. snacks: terminal = nil, then close the shown instance.  *)
Failed(w, p, t) ==
  LET w1 == [w EXCEPT !.job[t] = "failed"]
  IN IF p = "native"
     THEN IF NativeFailCleansUp
          THEN [w1 EXCEPT !.win[t] = FALSE, !.buf[t] = FALSE, !.mark[t] = FALSE, !.ntrack = None]
          ELSE w1
     ELSE LET w2 == [w1 EXCEPT !.strack = None]
          IN IF SnacksFailCleansUp THEN [w2 EXCEPT !.win[t] = FALSE, !.buf[t] = FALSE] ELSE w2

(* A whole start with no autocmd inside it: termopen starts Claude or raises. *)
AtomicStart(w, p) ==
  LET t == FreshT(w)
      s == Split(w, p, t)
  IN {Finish(Started(s, t), p, t), Failed(s, p, t)}

(* A whole open or toggle from an autocmd or a scheduled callback. *)
AtomicEntry(w, kind) ==
  UNION {IF o.start THEN IF HasFresh(o.w) THEN AtomicStart(o.w, Prov) ELSE {} ELSE {o.w}
         : o \in Entry(w, Prov, kind)}

AtomicOpen(w) == AtomicEntry(w, "open")

(* native.lua close_terminal / snacks.lua M.close up to vim.wait. Both adopt a terminal first, and stop the other   *)
(* provider's Claude when they find none of their own.                                                              *)
CloseBegin(w0, p) ==
  LET w == IF p = "snacks" THEN SnacksForgetEnded(w0) ELSE w0
      t0 == IF p = "native" THEN w.ntrack ELSE w.strack
      tracked == t0 # None /\ w.buf[t0]
      wa == IF p = "native" /\ ~tracked THEN [w EXCEPT !.ntrack = None] ELSE w   \* is_valid() forgets an invalid buffer
      ad == IF tracked THEN {}
            ELSE IF p = "native" THEN (IF NativeCloseAdopts THEN Adoptable(wa) ELSE {})
            ELSE (IF SnacksCloseAdopts THEN SnacksAdoptable(wa) ELSE {})
      t == IF tracked THEN t0 ELSE IF ad = {} THEN None ELSE CHOOSE b \in ad : TRUE
      wb == IF tracked \/ ad = {} THEN wa ELSE IF p = "native" THEN Adopt(wa, t) ELSE SnacksAdopt(wa, t)
      other == IF p = "native" THEN "snacks" ELSE "native"
      stops == OwnedStopOtherStops /\ IF p = "native" THEN NativeStopsSnacksClaude ELSE SnacksStopsNativeClaude
  IN IF t = None
     THEN [w |-> IF stops THEN StopAll(wb, Foreign(wb, other)) ELSE wb, t |-> None, wait |-> FALSE]
     ELSE LET w1 == IF p = "native"
                    THEN [wb EXCEPT !.ntrack = IF NativeCloseForgetsFirst THEN None ELSE @,
                                    !.mark[t] = IF NativeCloseClearsMark THEN FALSE ELSE @]
                    ELSE [wb EXCEPT !.strack = IF SnacksCloseForgetsFirst THEN None ELSE @,
                                    !.mark[t] = IF SnacksCloseClearsMark THEN FALSE ELSE @]
          IN [w |-> w1, t |-> t, wait |-> w.job[t] = "running"] \* jobstop returns 1, jobwait gives -1

(* After the wait: native deletes the buffer, snacks' closing:close() wipes *)
(* it (Win:close keeps the last window with a vsplit). Either ends the job. *)
CloseEnd(w, t) ==
  LET w1 == IF w.buf[t] THEN Wiped(w, t) ELSE w
  IN [w1 EXCEPT !.ntrack = IF @ = t THEN None ELSE @, !.strack = IF @ = t THEN None ELSE @]

(* One scheduled callback. *)
RunItem(w, i) ==
  CASE i.k = "snacksClose" -> IF w.buf[i.t] THEN Wiped(w, i.t) ELSE w   \* term_instance:close({ buf = true })
    [] i.k = "exit" ->                                                  \* native on_exit's scheduled function
         NativeForget(IF NativeExitClearsMark /\ w.buf[i.t] THEN [w EXCEPT !.mark[i.t] = FALSE] ELSE w, i.t, i.g)
    [] OTHER -> NativeForget(w, i.t, i.g)                               \* ClaudeCodeNativeAdopted TermClose

RECURSIVE CloseWins(_, _)
CloseWins(w, S) == IF S = {} THEN w ELSE LET u == CHOOSE x \in S : TRUE IN CloseWins(WinClosed(w, u), S \ {u})

Idle == pc.op = "idle"
Pumping == pc.op \in {"idle", "waiting"}   \* the main loop runs events
Calm == OpenBeforeCleanup \/ queue = {}

TypeOK ==
  /\ cfg \in [provider : Providers, autoClose : BOOLEAN, hidden : BOOLEAN]
  /\ loadable \in BOOLEAN /\ seen \in BOOLEAN /\ reloaded \in BOOLEAN
  /\ pc \in [op : {"idle", "begin", "split", "started", "waiting"}, t : Terms \cup {None},
             p : {None, "native", "snacks"}, re : BOOLEAN, cl : BOOLEAN]
  /\ asked \subseteq Terms /\ closed \subseteq Terms
  /\ job \in [Terms -> {"none", "running", "exited", "failed"}]
  /\ by \in [Terms -> {None, "native", "snacks"}]
  /\ gen \in [Terms -> Gens]
  /\ buf \in [Terms -> BOOLEAN] /\ win \in [Terms -> BOOLEAN] /\ swapped \in [Terms -> BOOLEAN]
  /\ mark \in [Terms -> BOOLEAN] /\ adoptedBy \in [Terms -> Gens \cup {None}]
  /\ others \in BOOLEAN
  /\ ntrack \in Terms \cup {None} /\ oldTrack \in Terms \cup {None} /\ oldWin \in BOOLEAN
  /\ strack \in Terms \cup {None}
  /\ queue \subseteq Items
  /\ bad \subseteq {"survived", "badOpen", "hideKilled", "hideError", "exitClosedOther", "exitError"}
  \* a window always exists
  /\ others \/ \E t \in Terms : win[t]

(* 'hidden' matters only for a buffer without bufhidden=hide, so the model *)
(* drops it when native sets bufhidden=hide.                                *)
Init ==
  /\ cfg \in [provider : Providers, autoClose : BOOLEAN,
              hidden : IF NativeKeepsHiddenJob THEN {TRUE} ELSE BOOLEAN]
  /\ loadable \in LoadableAtStart
  /\ seen = loadable   \* terminal.setup calls get_provider, which loads snacks.lua
  /\ reloaded = FALSE /\ pc = IdlePc /\ asked = {} /\ closed = {}
  /\ job = [t \in Terms |-> "none"] /\ by = [t \in Terms |-> None] /\ gen = [t \in Terms |-> "cur"]
  /\ buf = [t \in Terms |-> FALSE] /\ win = [t \in Terms |-> FALSE] /\ swapped = [t \in Terms |-> FALSE]
  /\ mark = [t \in Terms |-> FALSE] /\ adoptedBy = [t \in Terms |-> None]
  /\ others = TRUE
  /\ ntrack = None /\ oldTrack = None /\ oldWin = FALSE /\ strack = None
  /\ queue = {} /\ bad = {}

-----------------------------------------------------------------------------
(* Steps *)

(* :ClaudeCodeOpen or a send (kind "open"), :ClaudeCode or :ClaudeCodeFocus *)
(* (kind "toggle"): terminal.lua M.open / ensure_visible / simple_toggle /  *)
(* focus_toggle, which call get_provider each time. A start stops at the   *)
(* split, so that an autocmd can run before termopen.                      *)
YouOpen(kind) ==
  /\ Idle /\ Calm
  /\ \E o \in Entry(W, Prov, kind) :
       IF ~o.start THEN SetW(o.w) /\ UNCHANGED pc
       ELSE /\ HasFresh(o.w)
            /\ IF Prov = "native"
               THEN /\ SetW(o.w)        \* the vsplit and the new buffer come in SplitRuns; autocmds can run before
                    /\ pc' = [op |-> "begin", t |-> None, p |-> Prov, re |-> FALSE, cl |-> FALSE]
               ELSE /\ SetW(Split(o.w, Prov, FreshT(o.w)))
                    /\ pc' = [op |-> "split", t |-> FreshT(o.w), p |-> Prov, re |-> FALSE, cl |-> FALSE]
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, asked, closed>>

(* An autocmd calls open or a toggle while a start runs: WinLeave, WinNew,  *)
(* WinEnter or BufNew before the buffer has a mark ("begin"), BufEnter      *)
(* before termopen, or TermOpen after it. The model allows one per start.   *)
(* In "begin" a second start needs a second fresh terminal.                 *)
AutocmdCalls ==
  /\ AutocmdReenters /\ pc.op \in {"begin", "split", "started"} /\ ~pc.re
  /\ pc.op = "begin" => Cardinality({t \in Terms : by[t] = None}) >= 2
  /\ \E kind \in {"open", "toggle"} : \E v \in AtomicEntry(W, kind) : SetW(v)
  /\ pc' = [pc EXCEPT !.re = TRUE]
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, asked, closed>>

(* An autocmd of the start calls native.lua M.close. A close waits for the  *)
(* job to exit, and that wait cannot run inside termopen, so while a start   *)
(* runs it only records the request: `if starting then close_after_start =   *)
(* true; return end`. The start runs the close when it returns.             *)
CloseDuringStart ==
  /\ AutocmdReenters /\ NativeStarting /\ ~pc.cl
  /\ pc' = [pc EXCEPT !.cl = TRUE]
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, asked, closed, job, by, gen, buf, win, swapped, mark, adoptedBy, others,
                 ntrack, oldTrack, oldWin, strack, queue, bad>>

(* native.lua start_terminal: the vsplit has run, nvim_create_buf made the  *)
(* buffer, and the mark is set (NativeMarkBeforeTermopen).                  *)
SplitRuns ==
  /\ pc.op = "begin" /\ HasFresh(W)
  /\ SetW(Split(W, "native", FreshT(W)))
  /\ pc' = [op |-> "split", t |-> FreshT(W), p |-> "native", re |-> pc.re, cl |-> pc.cl]
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, asked, closed>>

(* native.lua open_terminal pcall(vim.fn.termopen); in snacks, termopen in  *)
(* Snacks.terminal.open under pcall. It starts Claude, or raises.           *)
TermopenRuns ==
  /\ pc.op = "split"
  /\ \/ SetW(Started(W, pc.t)) /\ pc' = [pc EXCEPT !.op = "started"]
     \/ SetW(Failed(W, pc.p, pc.t)) /\ pc' = IdlePc
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, asked, closed>>

(* The start returns. When an autocmd asked for a close, open_terminal runs  *)
(* it now, like a close you type (YouClose). Without NativeRunsDeferredClose *)
(* the request is lost, and the Claude that the start made runs on.          *)
(* A start whose termopen failed has nothing to stop, so TermopenRuns drops  *)
(* the request.                                                              *)
StartReturns ==
  /\ pc.op = "started"
  /\ LET w1 == Finish(W, pc.p, pc.t)
         run == {a \in Terms : w1.job[a] = "running"}
         c == CloseBegin(w1, pc.p)
         e == IF c.t = None THEN c.w ELSE CloseEnd(c.w, c.t)
     IN IF ~pc.cl
        THEN /\ SetW(w1) /\ pc' = IdlePc /\ UNCHANGED <<asked, closed>>
        ELSE IF ~NativeRunsDeferredClose
        THEN /\ SetW(IF run # {} THEN Flag(w1, "survived") ELSE w1) /\ pc' = IdlePc /\ UNCHANGED <<asked, closed>>
        ELSE IF c.wait
        THEN /\ SetW(c.w)
             /\ pc' = [op |-> "waiting", t |-> c.t, p |-> pc.p, re |-> FALSE, cl |-> FALSE]
             /\ asked' = run /\ closed' = closed \cup {c.t}
        ELSE /\ SetW(IF \E a \in run : e.job[a] = "running" THEN Flag(e, "survived") ELSE e)
             /\ closed' = IF c.t = None THEN closed ELSE closed \cup {c.t}
             /\ pc' = IdlePc /\ UNCHANGED asked
  /\ UNCHANGED <<cfg, loadable, seen, reloaded>>

(* :ClaudeCodeClose -> terminal.lua M.close -> provider close. A running   *)
(* job makes it wait in vim.wait; an exited one is wiped at once.          *)
YouClose ==
  /\ Idle
  /\ LET c == CloseBegin(W, Prov)
         run == {a \in Terms : job[a] = "running"}
     IN IF c.wait
        THEN /\ SetW(c.w)
             /\ pc' = [op |-> "waiting", t |-> c.t, p |-> Prov, re |-> FALSE, cl |-> FALSE]
             /\ asked' = run /\ closed' = closed \cup {c.t}
        ELSE LET e == IF c.t = None THEN c.w ELSE CloseEnd(c.w, c.t)
             IN /\ SetW(IF \E a \in run : e.job[a] = "running" THEN Flag(e, "survived") ELSE e)
                /\ closed' = IF c.t = None THEN closed ELSE closed \cup {c.t}
                /\ UNCHANGED <<pc, asked>>
  /\ UNCHANGED <<cfg, loadable, seen, reloaded>>

(* vim.wait returns (TermClose came, the buffer went, or 1 s passed). *)
CloseWaitEnds ==
  /\ pc.op = "waiting"
  /\ LET e == CloseEnd(W, pc.t)
     IN SetW(IF \E a \in asked : e.job[a] = "running" THEN Flag(e, "survived") ELSE e)
  /\ pc' = IdlePc /\ asked' = {}
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, closed>>

(* Inside vim.wait: a scheduled callback (an MCP request handler, a timer) *)
(* calls terminal.lua open or ensure_visible.                              *)
ScheduledOpen ==
  /\ pc.op = "waiting" /\ Calm
  /\ \E v \in AtomicOpen(W) : SetW(v)
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, pc, asked, closed>>

(* Claude exits on its own (/exit, a crash) or after jobstop. *)
ClaudeExits(t) ==
  /\ Pumping /\ job[t] = "running"
  /\ SetW(Exits(W, t))
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, pc, asked, closed>>

CallbackRuns(i) ==
  /\ Pumping /\ i \in queue
  /\ SetW(RunItem([W EXCEPT !.queue = @ \ {i}], i))
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, pc, asked, closed>>

(* :only in Claude's window closes every other window. *)
YouMakeItTheOnlyWindow(t) ==
  /\ OnlyWindow /\ Idle /\ win[t]
  /\ others \/ \E u \in Terms \ {t} : win[u]
  /\ SetW(CloseWins([W EXCEPT !.others = FALSE, !.swapped = [u \in Terms |-> FALSE]], {u \in Terms \ {t} : win[u]}))
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, pc, asked, closed>>

YouSplitAWindow ==
  /\ Idle /\ ~others
  /\ SetW([W EXCEPT !.others = TRUE])
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, pc, asked, closed>>

(* :e file in a native Claude window that is not the last window. snacks  *)
(* windows are fixbuf, so Snacks moves the other buffer out.              *)
YouShowAnotherBufferThere(t) ==
  /\ Swaps /\ Idle /\ by[t] = "native" /\ win[t] /\ ~IsLast(W, t)
  /\ NativeKeepsHiddenJob \/ cfg.hidden
  /\ SetW([NoWin(W, t) EXCEPT !.swapped[t] = TRUE, !.others = TRUE])
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, pc, asked, closed>>

YouWipeTheBuffer(t) ==
  /\ Wipes /\ Idle /\ buf[t]
  /\ SetW(Wiped(W, t))
  /\ UNCHANGED <<cfg, loadable, seen, reloaded, pc, asked, closed>>

(* :packadd snacks.nvim, or a plugin manager loads it later. *)
SnacksBecomesLoadable ==
  /\ Idle /\ ~loadable
  /\ loadable' = TRUE
  /\ UNCHANGED <<cfg, seen, reloaded, pc, asked, closed, job, by, gen, buf, win, swapped, mark, adoptedBy, others,
                 ntrack, oldTrack, oldWin, strack, queue, bad>>

(* package.loaded["claudecode..."] = nil and setup again (:Lazy reload). The *)
(* new copies start with empty state; queued callbacks and autocmd handlers  *)
(* keep running in the old copies.                                           *)
PluginReloads ==
  /\ Reloads /\ Idle /\ ~reloaded
  /\ \E p \in (IF ProviderChanges THEN Providers ELSE {cfg.provider}) : cfg' = [cfg EXCEPT !.provider = p]
  /\ reloaded' = TRUE /\ seen' = loadable
  /\ ntrack' = None /\ strack' = None
  /\ oldTrack' = ntrack /\ oldWin' = (ntrack # None /\ win[ntrack])
  /\ gen' = [t \in Terms |-> IF by[t] = None THEN "cur" ELSE "old"]
  /\ adoptedBy' = [t \in Terms |-> IF adoptedBy[t] = None THEN None ELSE "old"]
  /\ swapped' = [t \in Terms |-> FALSE]
  /\ queue' = {[i EXCEPT !.g = "old"] : i \in queue}
  /\ UNCHANGED <<loadable, pc, asked, closed, job, by, buf, win, mark, others, bad>>

Next ==
  \/ \E kind \in {"open", "toggle"} : YouOpen(kind)
  \/ AutocmdCalls
  \/ CloseDuringStart
  \/ SplitRuns
  \/ TermopenRuns
  \/ StartReturns
  \/ YouClose
  \/ CloseWaitEnds
  \/ ScheduledOpen
  \/ \E t \in Terms : ClaudeExits(t)
  \/ \E i \in Items : CallbackRuns(i)
  \/ \E t \in Terms : YouMakeItTheOnlyWindow(t)
  \/ YouSplitAWindow
  \/ \E t \in Terms : YouShowAnotherBufferThere(t)
  \/ \E t \in Terms : YouWipeTheBuffer(t)
  \/ SnacksBecomesLoadable
  \/ PluginReloads

Spec == Init /\ [][Next]_vars

(* TLC stops at the first broken rule, so it need not explore past one.    *)
(* check.sh passes this as the CONSTRAINT: TLC still checks every rule in  *)
(* the state that breaks it.                                               *)
AllRulesHold ==
  /\ bad = {}
  /\ Cardinality({t \in Terms : job[t] = "running"} \ (IF pc.op = "waiting" THEN {pc.t} ELSE {})) <= 1
  /\ \A t \in closed : ntrack # t /\ strack # t
  /\ \A t \in Terms : job[t] = "failed" => ~win[t] /\ ~buf[t] /\ ntrack # t /\ strack # t

-----------------------------------------------------------------------------
(* Rules *)

(* At most one Claude runs, apart from the one a close is stopping. *)
AtMostOneClaude ==
  Cardinality({t \in Terms : job[t] = "running"} \ (IF pc.op = "waiting" THEN {pc.t} ELSE {})) <= 1

(* When :ClaudeCodeClose returns, no Claude that ran when it began still runs. *)
CloseStopsClaude == "survived" \notin bad

(* The plugin never tracks again a terminal it began to close. *)
CloseNeverReuses == \A t \in closed : ntrack # t /\ strack # t

(* After an open, show or focus, you see a running Claude (except snacks with auto_close = false). *)
OpenShowsLiveClaude == "badOpen" \notin bad

(* Hiding Claude's window keeps Claude running. *)
HideKeepsClaude == "hideKilled" \notin bad

(* Hiding Claude's window raises no error. *)
HideNoError == "hideError" \notin bad

(* A failed start leaves no window, no buffer and no tracked terminal. *)
FailedStartLeavesNoWindow ==
  \A t \in Terms : job[t] = "failed" => ~win[t] /\ ~buf[t] /\ ntrack # t /\ strack # t

(* With auto_close, Claude's exit closes only Claude's own window, and never the last window. *)
ExitClosesOnlyOwnWindow == bad \cap {"exitClosedOther", "exitError"} = {}
=============================================================================
