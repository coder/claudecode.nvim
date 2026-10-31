---
name: verify-diff-lifecycle
description: Model-check the claudecode.nvim openDiff answer lifecycle (TLA+/TLC) against guards read from the current Lua code. Use after a change to how diffs are resolved, replaced, closed, or answered, or to how openDiff is called (lua/claudecode/diff.lua, diff_inline.lua, server/init.lua, server/client.lua, tools/init.lua, tools/open_diff.lua, tools/close_tab.lua, tools/close_all_diff_tabs.lua, the :ClaudeCodeCloseAllDiffs command in init.lua), and before trusting such a change.
---

# Verify the openDiff answer lifecycle

Claude calls `openDiff` and blocks until the plugin answers. If the plugin never answers, Claude hangs. If it answers wrongly, Claude writes a file the user rejected, or drops one the user accepted. This check explores every order of Claude calls, user actions, disconnects, and server stops in a small model, with each guard switched on or off to match the code as it is now.

## Rules

| Rule                        | Plain sentence                                                                                     | Harm when broken                                                           |
| --------------------------- | -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `AtMostOneAnswer`           | Claude gets at most one response per openDiff call.                                                | Claude acts on a second, contradicting answer.                             |
| `AnswerMatchesDiff`         | While a diff stays open, its status agrees with what Claude was told.                              | The user sees "accepted" while Claude was told "rejected", or the reverse. |
| `NoStrandedCall`            | A waiting call still has a pending diff and a response sender.                                     | Claude waits forever. No user action or close_tab can answer it.           |
| `SavedDiffKept`             | Only Claude tears down a diff the user accepted with `:w`, and never after its own client is gone. | The user's accepted edits vanish before Claude writes them.                |
| `DisconnectedCallsAnswered` | A disconnected client's waiting calls get answered without the user.                               | Orphaned diff windows linger (issue #248).                                 |

## Run

```bash
.agents/skills/verify-diff-lifecycle/check.sh            # about 10 s
.agents/skills/verify-diff-lifecycle/check.sh --keep     # same, keeps the TLC configs and output, prints the dir
.agents/skills/verify-diff-lifecycle/check.sh --mutants  # about 14 min, after you edit the model or a fact
.agents/skills/verify-diff-lifecycle/check.sh --record   # rewrite covered.lock, only after "Update after an intended change" (refused together with --mutants, and refused when covered.lock is a symlink)
```

Needs bash 4 or newer, Java 11 or newer (`JAVA=/path/to/java` overrides), `sha256sum` or `shasum`, and curl for the first run. The first run downloads TLC 1.7.4 to `~/.cache/claudecode-nvim-tla/` and refuses a jar whose sha256 differs. Run one copy at a time on a shared host. TLC is CPU heavy.

Exit codes:

- `0` is PASS.
- `1` means a rule broke.
- `2` is a tool or script error, or a model whose `TypeOK` breaks.
- `3` is STALE. The covered code changed since the model was last confirmed, so the change is unverified.

## Does the change touch the verified code?

Run the check. `covered.lock` records a hash of every Lua and Vimscript file under `lua/` and `plugin/`, so any change to the plugin's runtime code reads `STALE` (exit 3) until someone confirms that the model still describes the code. The model was written against the whole lifecycle: diff state, the tool and server layers, the transport that reports disconnects, and the user commands. Its facts cannot tell which other edits matter, so the record does not try to.

To show where to look, the record also hashes each block the model describes and lists every non-comment line that resolves, closes, registers or answers a diff, names the diff table (`active_diffs`, `_get_active_diffs`), or assigns a `.status`, with its enclosing top-level statement. The STALE output prints a `was:`/`now:` pair per changed file, block or call site. A new one prints only `now:`, and a removed one only `was:`. Control bytes in those lines print as `?`, so a source line cannot rewrite the terminal.

Covered blocks:

- In `diff.lua`: `_resolve_diff_as_saved`, `_resolve_diff_as_rejected`, `open_diff_blocking`, `_setup_blocking_diff`, `close_diff_by_tab_name`, `close_pending_diffs`, `close_diffs_for_client`, `close_active_diffs`, `_cleanup_all_active_diffs`, `_register_diff_state`, `_cleanup_diff_state`, `register_diff_autocmds` (the `:w`, `:q` and buffer-delete paths), `fire_diff_event`, `accept_current_diff`, `deny_current_diff`.
- In `diff_inline.lua`: `setup_inline_diff`, `resolve_inline_as_saved`, `resolve_inline_as_rejected`.
- In `server/init.lua`: `M.stop`, `on_disconnect`, `M._handle_request`, `M._setup_deferred_response`.
- In `tools/init.lua` and `tools/open_diff.lua`: `M.handle_invoke`, and the openDiff `handler`.
- In `init.lua`: the `ClaudeCodeCloseAllDiffs` user command.
- For client ownership: `holds_edits_for_other_client` and `close_all_diffs` in `diff.lua`, the `handler` in `tools/close_tab.lua` and `tools/close_all_diff_tabs.lua`, and `create_client` in `server/client.lua`.

A changed file with no changed block or call site still needs a look. A wrapper with another name, an alias of the diff table, or a transport path that skips `on_disconnect` (`server/tcp.lua`) shows only as a changed file. A PASS says the model holds for the guards the facts read, on code that matches the record. It does not review a change. STALE never means "probably fine".

## Read the result

`check.sh` prints the code facts first. Each fact is a guard that a regex reads from the source. `TRUE` means the regex found the guard. `FALSE` means the model runs without that guard. A `FALSE` you did not expect is either a removed guard (a bug) or a guard reworded past the regex (a modeling error). See below for how to tell them apart.

| Fact                                       | Code it reads                                                                                                                                                                                    |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `GuardSaved`, `GuardRejected`              | `if not diff_data or diff_data.status ~= "pending" then return` in each `_resolve_diff_as_*`                                                                                                     |
| `SenderCleared`                            | the resolution callback sets `_G.claude_deferred_responses[co_key] = nil` after it calls that sender                                                                                             |
| `ReplaceRejects`                           | in `open_diff_blocking`, before `coroutine.running()`: a pending diff with the same `tab_name` is rejected, then cleaned up                                                                      |
| `CloseTabRejectsPending`                   | `close_diff_by_tab_name` rejects a pending diff before cleanup                                                                                                                                   |
| `CloseEachByName`                          | `close_active_diffs` closes each match through `close_diff_by_tab_name`                                                                                                                          |
| `StopRejectsPending`                       | `M.stop` calls `close_pending_diffs`, then `stop_server`, then clears the senders                                                                                                                |
| `StopPendingOnly`, `DisconnectPendingOnly` | the `status == "pending"` filters in `close_pending_diffs` and `close_diffs_for_client`                                                                                                          |
| `DisconnectRejects`                        | `on_disconnect` schedules `close_diffs_for_client`                                                                                                                                               |
| `UserCloseAllPendingOnly`                  | `:ClaudeCodeCloseAllDiffs` calls `close_pending_diffs`, never `close_all_diffs`                                                                                                                  |
| `ClientTagged`                             | `handle_invoke` passes `client` to the tool, the openDiff handler passes `client.id` on, and both layouts store it as `client_id` when they register the diff                                    |
| `SetupAnswerReturned`                      | before `open_diff_blocking` yields, the resolution callback keeps its result instead of resuming the coroutine, and `open_diff_blocking` returns that result as the immediate reply (issue #325) |
| `OpenedEventInSetup`                       | `fire_diff_event` runs `nvim_exec_autocmds` directly, and `ClaudeCodeDiffOpened` fires inside setup, before the yield. Not a guard: `TRUE` lets a user handler resolve the diff during setup     |

The bulk closes, the Claude close tools, and client ids add four facts:

| Fact                      | Code it reads                                                                                                                                                             |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CloseRechecksFilter`     | `close_active_diffs` runs its filter through `matches` on the snapshot and again on `active_diffs[tab_name]` right before each close                                      |
| `CloseKeepsOthersSaved`   | `close_diff_by_tab_name(tab_name, client_id)` returns `false` on `holds_edits_for_other_client`. `handle_invoke` passes `client` to both tools, which pass `client.id` on |
| `ReplaceKeepsOthersSaved` | in `open_diff_blocking`, before the replace: `holds_edits_for_other_client` (a saved diff whose `client_id` is another client) makes the call `error`                     |
| `ClientIdsUnique`         | `create_client` in `server/client.lua` builds each id from the module counter `clients_created`, not from the handle address                                              |

On `BROKEN`, the script prints the TLC trace as action names. Read it with the pstack `/statechart` skill:

1. Rerun with `--keep`.
2. Copy the broken run's `.cfg` from the kept dir. Set `Reqs`, `Tabs` and `Clients` to one value each, then add a call only if the path needs two calls (a replacement on one `tab_name`) and a client only if it needs two clients. Stop at the smallest config that still breaks the rule.
3. Give `/statechart` the kept `DiffLifecycle.tla`, that cfg, and the view `model/statechart-view.ts`.

The report tells the path in plain words, for example "Claude calls openDiff, a ClaudeCodeDiffOpened handler accepts or denies, setup ends: waits, diff saved, nothing can answer". That is the path `SetupAnswerReturned=FALSE` takes (issue #325).

Then decide which kind of failure it is:

- **Real bug.** A fact went `FALSE` because the change removed or moved a guard, and the code can take the path. Replay the path on real Neovim with the `verify-claudecode-nvim` skill before you report it. Report it in the code's words. Never weaken a rule or the model to make it pass.
- **Modeling error.** The facts are `TRUE` but the path needs a step the code cannot take, or a fact reads `FALSE` because the guard was reworded and still works (for example `if not (diff_data and diff_data.status == "pending")`). Fix the regex or the model, run `--mutants`, and say what you changed.

## Update after an intended change

1. Read every `was:`/`now:` line of the STALE output and the code behind it.
   - If only `file` lines changed, and the change cannot reach diff state, an openDiff answer, a disconnect or a diff command (for example a terminal or selection change), say so in the PR. Then skip to step 4.
2. If the behavior changed, change the action in `model/DiffLifecycle.tla` that cites that code. If a guard moved, change its fact regex in `check.sh`. If a new caller resolves or closes diffs, model it as an action or add a fact for its guard.
3. Run `check.sh --mutants`. Every fact must be caught by its rule, and every rule must break at least once.
4. Run `check.sh` and read the result.
5. Run `check.sh --record` only once you have confirmed that the model describes the code at this commit. It records the merge base with `origin/main` when `lua/` and `plugin/` match it (so the record survives a squash merge), else `HEAD`. Commit `covered.lock` with the change.

## Scope and bounds

- The invariants run with 3 openDiff calls, 2 tab names and 2 clients, about 89,000 states. `DisconnectedCallsAnswered` runs with 2 calls, 2 tabs and 2 clients. It assumes weak fairness only on setup and on the scheduled disconnect cleanup. The user is never assumed to act.
- In every run, a user `ClaudeCodeDiffOpened` handler (README "Diff Lifecycle Events") can accept or deny the diff during setup: `:ClaudeCodeDiffAccept`, `:ClaudeCodeDiffDeny`, or a `nested = true` autocmd that closes the proposal window. A default handler that closes the window resolves nothing, because WinClosed does not fire inside a non-nested autocmd. Other handler actions during setup are not modeled.
- `SenderCleared` alone is caught by no rule, because the pending guards also stop a second answer. `--mutants` shows that `AtMostOneAnswer` breaks when both `SenderCleared` and `GuardRejected` are removed.
- `SavedDiffKept` knows which client owns each diff. A saved diff counts as lost when the user, a disconnect cleanup or a server stop tears it down, or when a client that does not own it does so while the owner is disconnected. A close by another client while the owner is connected counts as safe, because the owner got `FILE_SAVED` and can still write the file. The code is stricter than the rule: it keeps another client's saved diff in both cases. Ownership compares client ids, so a new connection must never get an old id. With `ClientIdsUnique` off, `ClientIdReused` lets a new connection take the id of a disconnected client.
- The split and unified layouts share the pending guards only because `resolve_inline_as_*` is reached through `_resolve_diff_as_*`. The inline functions have no guard of their own.
- Every run assumes that the user has a `ClaudeCodeDiffClosed` handler (`ClosedHandlerResolvesOther`). Each time a bulk close closes a diff, the handler can accept or deny one other open diff, in any order of the snapshot. After a single close (`close_tab`, a replacing openDiff) the handler can touch only other diffs, the same as a later user action, so only the bulk-close loop models it.
- These are not modeled:
  - a `ClaudeCodeDiffClosed` handler that starts another bulk close
  - window and tab layout
  - the `keep_empty` new-file cleanup inside `_resolve_diff_as_rejected` (it runs after the answer)
  - setup errors, which answer at once
  - Neovim exit (`VimLeavePre`) and the plugin's own `M.stop` in `init.lua`, beyond the server stop it calls
  - whether a sent response reaches a live socket
  - two servers in one Neovim
- A pass covers this model at these bounds, for the facts `check.sh` reads, on `lua/` and `plugin/` exactly as recorded in `covered.lock`. Any other tree reads STALE.
