---
name: verify-selection-tracking
description: Model-check what Claude sees as the user's current selection in claudecode.nvim (TLA+/TLC) against guards read from the current Lua code, and replay paths on headless Neovim. Use after a change to selection tracking (lua/claudecode/selection.lua, its enable/disable calls in lua/claudecode/init.lua, server.broadcast or on_connect in lua/claudecode/server/init.lua, or the getCurrentSelection and getLatestSelection tools), to the debounce or demotion timers, the visual-exit flush, or held-selection behavior (issue #246), and before trusting such a change.
---

# Verify selection tracking

While Claude is connected, `lua/claudecode/selection.lua` pushes the user's selection as a `selection_changed` notification. `getCurrentSelection` and `getLatestSelection` return the same value, `M.state.latest_selection`. Each send sets it first, so this check treats `latest_selection` as what Claude holds. If it is wrong, Claude answers about text the user did not select, about text that is gone, or about the wrong file. When nothing is tracked, `getCurrentSelection` reads the editor itself (#457, #463). The model makes no claim about that answer.

A selection survives Esc: Claude holds it until the cursor moves or its text changes (issue #246). The plugin keeps that hold in `last_active_visual_selection`, `cursor_at_flush` and `selection_tick`, and ends it from `CursorMoved`, `BufEnter`, `TextChanged`, `ModeChanged` and two one-shot timers.

The check explores every order of keys, mode changes, buffer switches, timer firings and timer callbacks in a small model, with each guard switched on or off to match the code as it is now. The model has no clock, so it covers every `visual_demotion_delay_ms`.

## Rules

| Rule                  | Plain sentence                                                                                                                                      | Harm when broken                                                                          |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `ReleaseSent`         | Right after you release a selection in a file (Esc), Claude holds it, also when you made it faster than the 100 ms debounce.                        | A quick selection never reaches Claude (issue #246).                                      |
| `NoPhantomSelection`  | Claude only gets text you selected, never the text at the `'<,'>` marks after an operator such as `d` changed it.                                   | Claude gets a selection the user never made.                                              |
| `NoTerminalSelection` | Claude never gets a selection in the Claude terminal buffer.                                                                                        | Claude's own prompt text becomes the context.                                             |
| `HeldUntilMoved`      | Once events settle, a selection you released stays with Claude while the cursor has not moved and its text is unchanged.                            | The selection the user means to ask about is gone before they type (issue #246).          |
| `HeldEndsWhenMoved`   | Once events settle, Claude holds a released selection only while the cursor has not moved since you released it.                                    | Claude answers about an old selection after the user moved on.                            |
| `SameFile`            | Once events settle in a file, Claude's selection is in that file.                                                                                   | Claude thinks the user is in another file.                                                |
| `ClaudeSeesCursor`    | Once events settle in a file, a cursor-only selection that Claude holds is where the cursor is, and in visual mode Claude holds the live selection. | Claude points at the wrong line or column.                                                |
| `NoDeletedText`       | Once events settle, Claude holds no selection text that its buffer no longer has.                                                                   | Claude answers about text the user deleted.                                               |
| `TimerClosedOnce`     | No timer handle is closed twice.                                                                                                                    | Neovim shows `handle ... is already closing`, a Lua error, while the user moves or types. |

"Once events settle" means no debounce or demotion timer runs and no timer callback waits in the `vim.schedule` queue.

## Run

```bash
.agents/skills/verify-selection-tracking/check.sh            # about 40 s
.agents/skills/verify-selection-tracking/check.sh --keep     # same, keeps the TLC configs and output, prints the dir
.agents/skills/verify-selection-tracking/check.sh --mutants  # about 25 min, after you edit the model or a fact
.agents/skills/verify-selection-tracking/check.sh --record   # rewrite covered.lock, only after "Update after an intended change"
.agents/skills/verify-selection-tracking/check.sh --hash-only  # under 1 s, no TLC: only compares covered.lock with the code
```

The shared harness is `scripts/tla/check-lib.sh` (read its header). It pins TLC 1.7.4 by sha256 and downloads it to `~/.cache/claudecode-nvim-tla/` on the first run. It needs bash 4 or newer, Java 11 or newer (`JAVA=/path/to/java` overrides), and `sha256sum` or `shasum`. CI runs every `.agents/skills/verify-*/check.sh`. Run one TLC job at a time on a shared host.

Exit codes:

- `0` is PASS.
- `1` means a rule broke.
- `2` is a tool or script error, or a model whose `TypeOK` breaks.
- `3` is STALE. The covered code changed since the model was last confirmed, so the change is unverified.

## Does the change touch the verified code?

Run `check.sh --hash-only`. `covered.lock` records, for each covered file, its hash, the hash of each block the model describes, and each line that reads or writes the selection state, a timer field, or calls a send, with its enclosing top-level statement. Any change to a covered file reads `STALE` (exit 3) and prints `was:`/`now:` lines for the changed file, blocks and sites.

Covered files and blocks:

- `lua/claudecode/selection.lua`: `cursor_unmoved_since_flush`, `clear_held_state`, `selection_text_is_there`, `demote_if_selection_text_changed`, `reconcile_held_selection`, `M.enable`, `M.disable`, `M._cancel_debounce_timer`, `M._cancel_demotion_timer`, `M._create_autocommands`, `M.on_cursor_moved`, `M.on_mode_changed`, `M.on_text_changed`, `M.debounce_update`, `M.update_selection`, `M.handle_selection_demotion`, `M.get_visual_selection_from_marks`, `M.flush_visual_selection`, `M.has_selection_changed`, `M.send_selection_update`, `M.is_claude_terminal_buffer`, `M.get_latest_selection`.
- `lua/claudecode/init.lua`: `M.start` (calls `selection.enable(M.state.server, visual_demotion_delay_ms)`) and `M.stop` (calls `selection.disable()`, then stops the server).
- `lua/claudecode/server/init.lua`: `M.broadcast` and the `on_connect` callback.
- `lua/claudecode/tools/get_current_selection.lua` and `get_latest_selection.lua`: the `handler`, which starts from `get_latest_selection()`.

`git log -- .agents/skills/verify-selection-tracking/covered.lock` shows each confirmation. Move it forward, with `--record`, only after you confirm that the model describes the code at the new commit.

Not covered, so a change there shows nothing: `lua/claudecode/utils.lua` `selection_type` (which modes count as visual), `lua/claudecode/terminal.lua` `get_active_terminal_bufnr` (the second check in `is_claude_terminal_buffer`), and `tools/get_open_editors.lua`, which also reads `get_latest_selection()`. A PASS says the model holds for the guards the facts read, on code that matches the record. It does not review a change. STALE never means "probably fine".

## Read the result

`check.sh` prints the code facts first. Each fact is a guard that a regex reads from the source. `TRUE` means the regex found the guard. `FALSE` means the model runs without that guard.

| Fact                      | Code it reads (all in `selection.lua`)                                                                                                                                                                                                           |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `FlushOnVisualExit`       | the `ModeChanged` autocmd calls `on_mode_changed`, which calls `M.flush_visual_selection()` when `leaving_visual`                                                                                                                                |
| `FlushSkipsOperator`      | `on_mode_changed` stores `visual_entry` (buffer and changedtick) when visual mode starts. The flush returns when the changedtick moved since then                                                                                                |
| `FlushSkipsTerminal`      | the flush returns when `M.is_claude_terminal_buffer(current_buf)`                                                                                                                                                                                |
| `FlushRecordsCursor`      | the flush sets `M.state.cursor_at_flush` to the buffer and the window cursor                                                                                                                                                                     |
| `UpdateSkipsTerminal`     | `update_selection` cancels the demotion and returns when `M.is_claude_terminal_buffer(current_buf)`                                                                                                                                              |
| `PendingKeepsHeld`        | in `update_selection`, while `M.state.demotion_timer` is set: `latest_selection` stays when `cursor_unmoved_since_flush`, else the cursor. That function compares the cursor with `cursor_at_flush` in the same buffer and reads `.left`         |
| `ElseClearsHeldState`     | `update_selection`'s last branch (no demotion, no held selection here) clears `last_active_visual_selection` and `cursor_at_flush`                                                                                                               |
| `DemotionWaitsForMove`    | `handle_selection_demotion` returns while `cursor_unmoved_since_flush` (Condition 3)                                                                                                                                                             |
| `DemotionClearsHeldState` | `handle_selection_demotion` clears the original buffer's `last_active_visual_selection` and `cursor_at_flush` after it demotes                                                                                                                   |
| `DebounceIgnoresStale`    | the debounce callback returns unless `M.state.debounce_timer` is its own timer                                                                                                                                                                   |
| `DemotionIgnoresStale`    | the demotion callback returns unless `M.state.demotion_timer` is its own timer                                                                                                                                                                   |
| `ClearsBeforeClose`       | both `_cancel_*_timer` functions and both callbacks set the state field to `nil` before `timer:close()`                                                                                                                                          |
| `EntryClearsHeld`         | `on_mode_changed` calls `clear_held_state()` when visual mode starts, except in the Claude terminal                                                                                                                                              |
| `FlushSkipReports`        | the flush skipped for an operator calls `clear_held_state()`, then `M.update_selection()` when `latest_selection` is not empty                                                                                                                   |
| `PendingClearsHeld`       | the cursor branch of `update_selection`'s pending-demotion case calls `clear_held_state()` when it reports the cursor                                                                                                                            |
| `ReconcileOnCursorMoved`  | `on_cursor_moved` calls `reconcile_held_selection(not entered_buffer)` before the debounce, and the `CursorMoved`, `CursorMovedI` and `BufEnter` autocmd passes `args.event == "BufEnter"` (the window cursor is not restored yet at `BufEnter`) |
| `ReconcileOnTextChanged`  | `on_text_changed` calls `reconcile_held_selection(true)` before the debounce, from the `TextChanged`, `TextChangedI` and `TextChangedP` autocmd                                                                                                  |
| `TextChangeReports`       | `reconcile_held_selection` returns after `demote_if_selection_text_changed()`, which clears the held state and calls `update_selection` when the changedtick moved since the selection was read and `selection_text_is_there` says no            |
| `MoveReports`             | `reconcile_held_selection` clears the held state and calls `update_selection` when `compare_cursor` and the cursor is not `cursor_unmoved_since_flush`                                                                                           |
| `LeaveNoted`              | `reconcile_held_selection` notes another buffer in `cursor_at_flush.away`, and sets `cursor_at_flush.left` for one that is not the Claude terminal, once the next event arrives                                                                  |
| `ReadRecordsTick`         | the flush and the in-visual `update_selection` record `selection_tick` (the buffer and its changedtick) next to the selection they read                                                                                                          |

Six guards break no rule alone, because another guard covers for them. `--mutants` removes each with the guard that covers for it, and the rule that breaks is the one `EXPECT` in `check.sh` names:

| Removed together                                      | Rule that breaks    | The two guards                                                                                                                                |
| ----------------------------------------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `DemotionClearsHeldState` and `MoveReports`           | `ClaudeSeesCursor`  | The demotion forgets the held selection after it reports the cursor. A cursor move reports the cursor and forgets the held selection at once. |
| `PendingClearsHeld` and `ReconcileOnCursorMoved`      | `ClaudeSeesCursor`  | A pending-demotion update forgets the held selection when it reports the cursor. `CursorMoved` and `BufEnter` reconcile the hold at once.     |
| `ElseClearsHeldState` and `LeaveNoted`                | `SameFile`          | The last branch of `update_selection` forgets the held selection. A buffer entered other than the Claude terminal ends the hold.              |
| `EntryClearsHeld` and `FlushSkipReports`              | `HeldEndsWhenMoved` | A new visual selection forgets the held one. A flush skipped for an operator forgets it.                                                      |
| `ReconcileOnTextChanged` and `ReconcileOnCursorMoved` | `NoDeletedText`     | `TextChanged` and `CursorMoved` both run the text check, and a key that edits at the cursor fires both.                                       |

The model also has three environment switches that are not facts. `check.sh` sets them in `tla_constants`:

- `DelayBelowDebounce`: `TRUE` restricts the model to the default order (`visual_demotion_delay_ms` 50 < `debounce_ms` 100): a demotion timer fires before any debounce timer started after it. `check.sh` uses `FALSE`, which covers every delay.
- `WithTerminal`: `TRUE` lets the user go to a Claude terminal buffer. `FALSE` models `terminal.provider = "none"` or `"external"`. `check.sh` always uses `TRUE`.
- `MaxEdits`: edits per file, 1.

On `BROKEN`, the script prints the TLC trace as action names. Each action names the step it models: `YouStartSelecting`, `YouExtendSelection`, `YouReleaseSelection` (Esc), `YouEditSelection` (`d`, `c`), `YouMoveCursor`, `YouEditAtCursor` (`x`), `YouEditElsewhere`, `YouSwitchBuffer`, and for each timer `...TimerFires` (the uv timer fires and queues its callback) and `...CallbackRuns`. Read the trace with the pstack `/statechart` skill:

1. Rerun with `--keep`.
2. Copy the broken run's `.cfg` from the kept dir. Shrink it: `Files = {f1}` unless the rule is `SameFile`, `Ranges = {r1}`, `Pos = {p1}` unless the path moves the cursor, `MaxEdits = 0` unless it edits, `WithTerminal = FALSE` unless it visits the Claude terminal. Stop at the smallest config that still breaks the rule.
3. Give `/statechart` the kept `SelectionTracking.tla`, that cfg, and the view `model/statechart-view.ts`.

The report tells the path in plain words, for example "you start selecting, you press Esc, you press x on the cursor, 100 ms pass, the plugin updates Claude: Claude holds text you deleted from a.txt". That is the path of the `NoDeletedText` bug below.

Then decide which kind of failure it is:

- **Real bug.** A fact went `FALSE` because the change removed or moved a guard, or the facts are `TRUE` and the path is one the code can take. Replay it on headless Neovim with a probe in `replays/` (see below) before you report it. Report it in the code's words. Never weaken a rule or the model to make it pass.
- **Modeling error.** The facts are `TRUE` but the path needs a step the code cannot take, or a fact reads `FALSE` because the guard was reworded and still works. Fix the regex or the model, run `--mutants`, and say what you changed. If a replay does not show the bug, assume the model is wrong until you show it is not.

## Replays

Each probe in `replays/` starts the plugin through the real `require("claudecode").start()` with `terminal.provider = "none"`, then types keys through Neovim's main loop with real timers. It replaces only `server.broadcast`, in its own process, to record each `selection_changed`. It prints one line per step, the settled state, `OK` or `BUG`, and a count line. Each probe replays a path that once broke a rule (see "Bugs this model found"), so `OK` shows the promise kept.

```bash
NVIM=~/.local/share/mise/installs/neovim/0.12.3/bin/nvim \
  .agents/skills/verify-selection-tracking/replays/run.sh held_after_operator.lua
```

`run.sh` puts this checkout first on `runtimepath` and gives each run a fresh `XDG_*_HOME`, `CLAUDE_CONFIG_DIR` and `TMPDIR` under `$XUM_SCRATCH_DIR` (or `/tmp`), removed afterwards. `DELAY_MS=50` reruns the two long-delay probes (`other_file_after_return.lua`, `cursor_after_return.lua`) with the default delay. They use 1000 ms.

| Probe                         | Keys                                            | Rule                                 |
| ----------------------------- | ----------------------------------------------- | ------------------------------------ |
| `held_after_operator.lua`     | `vb`, Esc, `gv`, `d`                            | `HeldEndsWhenMoved`, `NoDeletedText` |
| `held_after_quick_move.lua`   | `ve`, Esc, `l`, then `h` 30 ms later            | `HeldEndsWhenMoved`                  |
| `held_after_edit.lua`         | `viw`, Esc, `x`, `x`                            | `NoDeletedText`                      |
| `other_file_after_return.lua` | `ve`, Esc, `:b b.txt`, `:b a.txt`, a long delay | `SameFile`                           |
| `cursor_after_return.lua`     | `ve`, Esc, `l`, `h` 250 ms later, a long delay  | `ClaudeSeesCursor`                   |

## Bugs this model found

The first version of the model found four broken rules on the code before #452. Each was replayed on Neovim 0.12.3 with the probe named, and #452 fixed all four:

1. **`HeldEndsWhenMoved`: Claude kept a released selection after the cursor left it, when the cursor stood where the selection was released again by the time the debounce fired.** You select `alpha` backwards (`vb`), press Esc, press `gv`, press `d` (`held_after_operator.lua`). Or you select `alpha` (`ve`), press Esc, press `l` and then `h` within 100 ms (`held_after_quick_move.lua`). The plugin compared the cursor with `cursor_at_flush` only when a timer fired, and a new selection or an operator did not clear it.
2. **`NoDeletedText`: Claude kept a held selection after you edited its text without moving the cursor.** You select `alpha` (`viw`), press Esc, then `x` twice. Claude still held `alpha` after the line became `alphbeta gamma` (`held_after_edit.lua`). Nothing compared the held text with the buffer.
3. **`SameFile`: with a long `visual_demotion_delay_ms`, Claude held another file's cursor.** With 1000 ms: you select `alpha` in `a.txt`, press Esc, `:b b.txt`, `:b a.txt`. Claude held `b.txt` 0:0 until the cursor moved (`other_file_after_return.lua`).
4. **`ClaudeSeesCursor`: with a long `visual_demotion_delay_ms`, Claude held a cursor position you had left.** With 1000 ms: you select `alpha`, press Esc, press `l`, wait, press `h`. The cursor was at 0:4 and Claude held 0:5 (`cursor_after_return.lua`).

#452 ends the hold when the cursor leaves, when a new selection starts, when an operator consumes the selection, and when its text changes. The model has each as a guard (`MoveReports`, `EntryClearsHeld`, `FlushSkipReports`, `TextChangeReports`).

A review of #452 found one more path, and #471 fixed it: Claude holds selection A, you start selection B, an operator consumes B before the 100 ms in-visual debounce, and you enter the Claude terminal inside that 100 ms. Claude kept A for the whole visit. The model's flush-skip step (`FlushSkipReports`) describes the fixed code. `tests/integration/selection_held_spec.lua` replays that path with a real terminal buffer.

## Update after an intended change

1. Read every `was:`/`now:` line of the STALE output and the code behind it.
   - If only `file` lines changed, and the change cannot reach the selection state, a timer, a send, or the tools (for example a diff or terminal change in `init.lua`), say so in the PR. Then skip to step 4.
2. If the behavior changed, change the action or operator in `model/SelectionTracking.tla` that cites that code (`Update`, `Demote`, `Flush`, `Reconcile`, `OnModeChanged`, `DebounceUpdate`, the `Cancel*` operators, or a `You*` step). If a guard moved, change its fact regex in `check.sh`. If a rule breaks on the new code, that is a finding: replay it, and fix the code, not the rule.
3. Run `check.sh --mutants`. Every fact must be caught by its rule, alone or in a listed pair (`EXPECT`), and every rule must break at least once.
4. Run `check.sh` and read the result.
5. Run `check.sh --record` only once you have confirmed that the model describes the code at this commit. Commit `covered.lock` with the change.

## Scope and bounds

- The main run uses 2 files, the Claude terminal, 2 cursor positions, 2 selection ranges and 1 edit per file, any `visual_demotion_delay_ms` (89,313 distinct states). The `--mutants` runs use 1 file, except `SameFile` with 2.
- One model step is one key or command together with the autocmds it fires (`ModeChanged`, `TextChanged`, `CursorMoved`, `BufEnter`). They run in the same main-loop iteration as the key, before Neovim polls libuv again, so no timer callback runs between them. A window command such as `<C-w>w` in visual mode fires `ModeChanged` in the old buffer first (checked on Neovim 0.12.3), so the model splits it into Esc and a buffer switch. Each uv timer firing and each scheduled callback is its own step. The model can fire a timer between any two keys, which also covers typeahead.
- An operator in visual mode (`d`, `c`, `>`) ends visual mode after the changedtick moved (checked on Neovim 0.12.3 for `d`) and lands the cursor on any position.
- At `BufEnter` the window cursor is not restored yet, so the model compares it only at `CursorMoved` and `TextChanged`. A new Claude terminal is not registered when `BufEnter` fires, so the model lets the plugin not know it yet (`termKnown`) and decide at the next event.
- An edit changes the held text (`YouEditSelection`, `YouEditAtCursor`) or leaves it alone (`YouEditElsewhere`). An edit that moves the held range's lines, such as a line added above, is not modeled. The code reads the range again with `nvim_buf_get_text`, and reports the cursor when the held text is not there. This was read from the code, not replayed.
- `latest_selection` is what Claude holds: every send sets it first, `M.server` is always set while tracking runs, and both tools return it when it is set.
- `is_claude_terminal_buffer` finds the Claude terminal by a `term://` buffer name whose command contains `claude`, or by `terminal.get_active_terminal_bufnr()`. The model has one terminal buffer, `Term`, and treats both checks as one.
- "After `:ClaudeCodeStop` nothing is sent" is not a rule, because no `selection.lua` guard can break it alone. `init.lua` `M.stop` calls `selection.disable()`, which clears the autocmds, both timers and `M.server`, and then stops the server, and `server.broadcast` returns `false` without a server. Start, stop and restart are not modeled.
- Not modeled: Select mode as distinct from Visual mode, empty selections (the flush skips them), a second Claude terminal, `send_current_selection` (no caller in `lua/`), `:ClaudeCodeSend` at-mentions, and insert mode as distinct from normal mode.
- Coming back from the Claude terminal to the file of a held selection with the cursor where it was, the model allows Claude to hold either the selection or the cursor (`holdLoose`), and `HeldUntilMoved` and `HeldEndsWhenMoved` make no claim there.
- A Claude that connects after the last change gets no `selection_changed` until the selection changes: `on_connect` sends none, and `has_selection_changed` stops a resend of an unchanged selection. PROTOCOL.md promises a notification only when the selection changes, and the tools answer on request, so this is not a rule.
- A pass covers this model at these bounds, for the facts `check.sh` reads, on the covered files exactly as recorded in `covered.lock`. Any other tree reads STALE.
