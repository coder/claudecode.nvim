---
name: verify-diff-lifecycle
description: Model-check the claudecode.nvim openDiff answer lifecycle (TLA+/TLC) against guards read from the current Lua code. Use after a change to how diffs are resolved, replaced, closed, or answered, or to how openDiff is called (lua/claudecode/diff.lua, diff_inline.lua, server/init.lua, tools/init.lua, tools/open_diff.lua, the :ClaudeCodeCloseAllDiffs command in init.lua), and before trusting such a change.
---

# Verify the openDiff answer lifecycle

Claude calls `openDiff` and blocks until the plugin answers. If the plugin never answers, Claude hangs. If it answers wrongly, Claude writes a file the user rejected, or drops one the user accepted. This check explores every order of Claude calls, user actions, disconnects, and server stops in a small model, with each guard switched on or off to match the code as it is now.

## Rules

| Rule                        | Plain sentence                                                        | Harm when broken                                                           |
| --------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `AtMostOneAnswer`           | Claude gets at most one response per openDiff call.                   | Claude acts on a second, contradicting answer.                             |
| `AnswerMatchesDiff`         | While a diff stays open, its status agrees with what Claude was told. | The user sees "accepted" while Claude was told "rejected", or the reverse. |
| `NoStrandedCall`            | A waiting call still has a pending diff and a response sender.        | Claude waits forever. No user action or close_tab can answer it.           |
| `SavedDiffKept`             | Only Claude tears down a diff the user accepted with `:w`.            | The user's accepted edits vanish before Claude writes them.                |
| `DisconnectedCallsAnswered` | A disconnected client's waiting calls get answered without the user.  | Orphaned diff windows linger (issue #248).                                 |

## Run

```bash
.agents/skills/verify-diff-lifecycle/check.sh            # about 10 s
.agents/skills/verify-diff-lifecycle/check.sh --keep     # same, keeps the TLC configs and output, prints the dir
.agents/skills/verify-diff-lifecycle/check.sh --mutants  # about 4 min, after you edit the model or a fact
.agents/skills/verify-diff-lifecycle/check.sh --record   # rewrite covered.lock, only after "Update after an intended change"
```

Needs bash 4 or newer, Java 11 or newer (`JAVA=/path/to/java` overrides), `sha256sum` or `shasum`, and curl for the first run. The first run downloads TLC 1.7.4 to `~/.cache/claudecode-nvim-tla/` and refuses a jar whose sha256 differs. Run one copy at a time on a shared host. TLC is CPU heavy.

Exit codes:

- `0` is PASS.
- `1` means a rule broke, or the known finding changed.
- `2` is a tool or script error.
- `3` is STALE. The covered code changed since the model was last confirmed, so the change is unverified.

## Does the change touch the verified code?

Run the check. It hashes every block the model describes and lists every non-comment line under `lua/` that resolves, closes, registers, or answers a diff. `covered.lock` records both, with the sync commit on its first line. When either differs, the run prints `STALE` with one `was:`/`now:` line per changed block or call site, and exits 3 even if every rule holds.

Covered blocks:

- In `diff.lua`: `_resolve_diff_as_saved`, `_resolve_diff_as_rejected`, `open_diff_blocking`, `_setup_blocking_diff`, `close_diff_by_tab_name`, `close_pending_diffs`, `close_diffs_for_client`, `close_active_diffs`, `_cleanup_all_active_diffs`.
- In `diff_inline.lua`: `resolve_inline_as_saved`, `resolve_inline_as_rejected`.
- In `server/init.lua`: `M.stop`, `on_disconnect`, `M._handle_request`.
- In `tools/init.lua` and `tools/open_diff.lua`: `M.handle_invoke`, and the openDiff `handler`.
- In `init.lua`: the `ClaudeCodeCloseAllDiffs` user command.

STALE never means "probably fine". A new direct caller of `resolve_inline_as_*` or `_cleanup_all_active_diffs` shows up only as STALE, because no fact reads it, and both can strand a call or drop a saved diff. Read every `was:`/`now:` line before you go on.

## Read the result

`check.sh` prints the code facts first. Each fact is a guard that a regex reads from the source. `TRUE` means the regex found the guard. `FALSE` means the model runs without that guard. A `FALSE` you did not expect is either a removed guard (a bug) or a guard reworded past the regex (a modeling error). See below for how to tell them apart.

| Fact                                       | Code it reads                                                                                                                                            |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GuardSaved`, `GuardRejected`              | `if not diff_data or diff_data.status ~= "pending" then return` in each `_resolve_diff_as_*`                                                             |
| `SenderCleared`                            | both `_G.claude_deferred_responses[co_key] = nil` lines in the resolution callback                                                                       |
| `ReplaceRejects`                           | in `open_diff_blocking`, before `coroutine.running()`: a pending diff with the same `tab_name` is rejected, then cleaned up                              |
| `CloseTabRejectsPending`                   | `close_diff_by_tab_name` rejects a pending diff before cleanup                                                                                           |
| `CloseEachByName`                          | `close_active_diffs` closes each match through `close_diff_by_tab_name`                                                                                  |
| `StopRejectsPending`                       | `M.stop` calls `close_pending_diffs`, then `stop_server`, then clears the senders                                                                        |
| `StopPendingOnly`, `DisconnectPendingOnly` | the `status == "pending"` filters in `close_pending_diffs` and `close_diffs_for_client`                                                                  |
| `DisconnectRejects`                        | `on_disconnect` schedules `close_diffs_for_client`                                                                                                       |
| `UserCloseAllPendingOnly`                  | `:ClaudeCodeCloseAllDiffs` calls `close_pending_diffs`, never `close_all_diffs`                                                                          |
| `ClientTagged`                             | `handle_invoke` passes `client` to the tool, and the openDiff handler passes `client.id` on                                                              |
| `OpenedEventInSetup`                       | `ClaudeCodeDiffOpened` fires inside setup, the callback resumes the coroutine without a status check, and the sender is stored after the handler returns |

On `BROKEN`, the script prints the TLC trace as action names. Read it with the pstack `/statechart` skill:

1. Rerun with `--keep`.
2. Copy the broken run's `.cfg` from the kept dir. Set `Reqs`, `Tabs` and `Clients` to one value each, then add a call only if the path needs two calls (a replacement on one `tab_name`) and a client only if it needs two clients. Stop at the smallest config that still breaks the rule.
3. Give `/statechart` the kept `DiffLifecycle.tla`, that cfg, and the view `model/statechart-view.ts`.

The report tells the path in plain words, for example "Claude calls openDiff, a ClaudeCodeDiffOpened handler accepts or denies, setup finishes, the call waits: waits, diff saved, nothing can answer".

Then decide which kind of failure it is:

- **Real bug.** A fact went `FALSE` because the change removed or moved a guard, and the code can take the path. Replay the path on real Neovim with the `verify-claudecode-nvim` skill before you report it. Report it in the code's words. Never weaken a rule or the model to make it pass.
- **Modeling error.** The facts are `TRUE` but the path needs a step the code cannot take, or a fact reads `FALSE` because the guard was reworded and still works (for example `if not (diff_data and diff_data.status == "pending")`). Fix the regex or the model, run `--mutants`, and say what you changed.

## Known finding (reported, not fixed)

The `opened-handler` run is expected to break `NoStrandedCall`. Suppose a user `ClaudeCodeDiffOpened` handler (README "Diff Lifecycle Events") runs `:ClaudeCodeDiffAccept` or `:ClaudeCodeDiffDeny`, or closes the proposal window from a `nested = true` autocmd. That handler resolves the diff while `open_diff_blocking` is still in setup. The resolution callback tries to resume the running coroutine, which fails with `cannot resume running coroutine`. The response sender does not exist yet, so nothing is sent. The diff is marked saved or rejected, and Claude waits forever. Later `close_tab` calls answer nothing either. A default (non-nested) handler that closes the window does not trigger it, because WinClosed does not fire inside it.

Replayed on real Neovim 0.12.3 on 2026-10-31 with `verify-claudecode-nvim`:

1. Register the handler: `$V keys -l ':lua vim.api.nvim_create_autocmd("User", { pattern = "ClaudeCodeDiffOpened", callback = function() vim.cmd("ClaudeCodeDiffDeny") end })'`, then `$V keys Enter`.
2. Send `openDiff`.
3. `$V await <id> 20` times out. `active_diffs` shows `rejected`, and `:messages` shows the coroutine error.

If a fix lands, `OpenedEventInSetup` turns `FALSE` and the script reports `NO LONGER REPRODUCES`. A `FALSE` fact only disables the step, so read the fix and model what it does. Then remove the `opened-handler` run from `check.sh` and this section.

## Update after an intended change

1. Read every `was:`/`now:` line of the STALE output and the code behind it.
2. If the behavior changed, change the action in `model/DiffLifecycle.tla` that cites that code. If a guard moved, change its fact regex in `check.sh`. If a new caller resolves or closes diffs, model it as an action or add a fact for its guard.
3. Run `check.sh --mutants`. Every fact must be caught by its rule, and every rule must break at least once.
4. Run `check.sh` and read the result.
5. Run `check.sh --record` only once you have confirmed that the model describes the code at this commit. It records the merge base with `origin/main` when `lua/` matches it (so the record survives a squash merge), else `HEAD`. Commit `covered.lock` with the change.

## Scope and bounds

- The invariants run with 3 openDiff calls, 2 tab names and 2 clients, about 65,000 states. `DisconnectedCallsAnswered` runs with 2 calls, 2 tabs and 2 clients. It assumes weak fairness only on setup and on the scheduled disconnect cleanup. The user is never assumed to act.
- `SenderCleared` alone is caught by no rule, because the pending guards also stop a second answer. `--mutants` shows that `AtMostOneAnswer` breaks when both `SenderCleared` and `GuardRejected` are removed.
- The split and unified layouts share the pending guards only because `resolve_inline_as_*` is reached through `_resolve_diff_as_*`. The inline functions have no guard of their own.
- These are not modeled:
  - window and tab layout
  - the `keep_empty` new-file cleanup inside `_resolve_diff_as_rejected` (it runs after the answer)
  - setup errors, which answer at once
  - Neovim exit (`VimLeavePre`) and the plugin's own `M.stop` in `init.lua`, beyond the server stop it calls
  - whether a sent response reaches a live socket
  - two servers in one Neovim
- A pass covers this model at these bounds, for the facts `check.sh` reads. It proves nothing about code the facts do not read. STALE marks that code.
