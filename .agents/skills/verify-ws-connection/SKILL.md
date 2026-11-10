---
name: verify-ws-connection
description: Model-check the claudecode.nvim WebSocket connection lifecycle (TLA+/TLC) against guards read from the current Lua code, from the TCP accept through the handshake, requests, Close frames, keepalive pings and server stop. Use after a change to lua/claudecode/server/client.lua, server/tcp.lua, server/handshake.lua, the start/stop or callback wiring in server/init.lua, or M.start/M.stop in init.lua, and before trusting such a change.
---

# Verify the WebSocket connection lifecycle

Claude Code talks to the plugin over one WebSocket connection. The plugin must not run a request from a Claude that is gone, must report each disconnect once, must tell Claude why it closes, must not drop a Claude that answers its pings, and must not keep a dead connection or its socket forever. This check explores every order of Claude's frames, hang-ups and stalls, libuv read and write callbacks, ping-timer ticks, scheduled callbacks and server stops in a small model of one connection, with each guard switched on or off to match the code as it is now.

## Rules

| Rule                     | Plain sentence                                                                                                                                                                                                                                                              | Harm when broken                                                                                                                                   |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NoRequestAfterEnd`      | A request from Claude runs only after its 101 reply was written, and never after the plugin started to close the connection or saw it end.                                                                                                                                  | A request from a Claude that hung up or closed still changes the editor (opens a diff, moves the cursor), and its answer goes nowhere.             |
| `DisconnectReportedOnce` | `on_disconnect` runs at most once per client.                                                                                                                                                                                                                               | The disconnect cleanup (closing that client's pending diffs) runs twice.                                                                           |
| `StatusCloseDelivered`   | A Close frame for a protocol error (1002, 1003, 1007, 1009) or a server stop (1001) is written before the plugin closes the socket.                                                                                                                                         | Claude cannot tell a protocol error or a shutdown from a crash: the connection just drops.                                                         |
| `NoFalseTimeout`         | The ping timer drops a client only after two intervals of awake time without a pong, and only at the second tick in a row that finds none. A suspended or blocked Neovim, and a tick that runs late before the plugin reads Claude's pong, do not count against the client. | A Claude that answers every ping is disconnected with 1011.                                                                                        |
| `DeadClientDropped`      | A client whose Claude hung up or stopped answering, or whose connection the plugin started to close, eventually leaves `server.clients` with its `on_disconnect`.                                                                                                           | The plugin keeps counting Claude as connected (`is_claude_connected()`), keeps the unsent writes in memory, and never runs the disconnect cleanup. |
| `DroppedSocketCloses`    | Once a client left `server.clients`, or the server stopped, its socket eventually closes, as long as Claude reads again.                                                                                                                                                    | The socket stays open, in `CLOSE_WAIT` once Claude hangs up, until Neovim exits: one leaked file descriptor each time.                             |

`DeadClientDropped` and `DroppedSocketCloses` are liveness rules ("eventually"). The others hold in every state. TLC reports only the first broken invariant of a run, and a `NoFalseTimeout` break is shorter than any other break, so `check.sh` checks `NoFalseTimeout` in a run of its own (`live-NoFalseTimeout`, written as `[](~falseTimeout)`). A new break of the other three then still shows in the `main` run.

## Run

```bash
.agents/skills/verify-ws-connection/check.sh            # about 30 s
.agents/skills/verify-ws-connection/check.sh --keep     # same, keeps the TLC configs and output, prints the dir
.agents/skills/verify-ws-connection/check.sh --mutants  # about 10 min, after you edit the model or a fact
.agents/skills/verify-ws-connection/check.sh --record   # rewrite covered.lock, only after "Update after an intended change" (refused together with --mutants)
.agents/skills/verify-ws-connection/check.sh --hash-only  # a few seconds, no TLC: only compares covered.lock with the code (exit 0 or 3)
```

The shared harness `scripts/tla/check-lib.sh` does the work. Its header lists what `check.sh` sets. CI's `covered-lock` job runs every `.agents/skills/verify-*/check.sh` on each pull request, with the TLC jar cached. `Required` does not need that job. On the code as written this check passes, so a broken rule or `STALE` in that job's log for this check is news.

Needs bash 4 or newer, Java 11 or newer (`JAVA=/path/to/java` overrides), `sha256sum` or `shasum`, and curl for the first run, which downloads TLC 1.7.4 to `~/.cache/claudecode-nvim-tla/` and refuses a jar whose sha256 differs. Run one copy at a time on a shared host: TLC is CPU heavy.

Exit codes:

- `0` is PASS.
- `1` means a rule broke.
- `2` is a tool or script error, or a model whose `TypeOK` breaks.
- `3` is STALE. The covered code changed since the model was last confirmed, so the change is unverified.

## Does the change touch the verified code?

Run `check.sh --hash-only`. `covered.lock` records a hash of each covered file: `server/client.lua`, `server/tcp.lua`, `server/handshake.lua`, `server/init.lua` and `init.lua`. Any change to one of them reads `STALE` (exit 3) until someone confirms that the model still describes the code. `git log -1 -- .agents/skills/verify-ws-connection/covered.lock` gives the sync commit: the last commit at which someone confirmed the model against the code. Move it forward only by `check.sh --record`, after "Update after an intended change".

To show where to look, the record also hashes each block the model describes and lists every non-comment line that changes a client's state, writes to or closes its socket, or adds, drops, stops or times out a client, with its enclosing top-level statement. The STALE output prints a `was:`/`now:` pair per changed file, block or line. Covered blocks:

- In `server/client.lua`: `create_client`, `add_data_frame`, `fail_connection`, `process_data` (handshake, 101 write callback, frames, Close, PONG, the scheduled `on_message` guard), `send_message`, `send_ping`, `close_client`, `is_client_alive`.
- In `server/tcp.lua`: `_handle_new_connection` (accept, `read_start`, EOF and read errors), `release_socket`, `_disconnect_client`, `_remove_client`, `stop_server`, `start_ping_timer`.
- In `server/handshake.lua`: `process_handshake`, `extract_http_request`.
- In `server/init.lua`: `M.start` (the callbacks and the ping timer), `M.stop`.
- In `init.lua`: `M.start`, `M.stop` (`:ClaudeCodeStop` and `VimLeavePre` call it).

A changed file with no changed block or line still needs a look, for example a new caller of `close_client` in another function. A PASS says the model holds for the guards the facts read, on code that matches the record. It does not review a change. STALE never means "probably fine".

When two branches change the same covered file, `covered.lock` conflicts. Merge `origin/main`, follow "Update after an intended change" on the merged code, run `check.sh --record`, and commit the merge with the new `covered.lock`.

## Read the result

`check.sh` prints the code facts first. Each fact is a guard that a regex reads from the source. `TRUE` means the regex found the guard. `FALSE` means the model runs without that guard. A `FALSE` you did not expect is either a removed guard (a bug) or a guard reworded past the regex (a modeling error).

| Fact                         | Code it reads                                                                                                                                                                                                                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `UpgradeInWriteCallback`     | `process_data` sets `state = "upgrading"` on a good handshake, and sets `handshake_complete = true` and `state = "connected"` only in the 101 write callback, after `if err or not success`                                                                                                            |
| `UpgradeRechecksState`       | the 101 write callback returns when `client.state ~= "upgrading" or client.tcp_handle:is_closing()`, before it sets `handshake_complete`                                                                                                                                                               |
| `UpgradeStartsKeepalive`     | the 101 write callback sets `client.last_pong = vim.loop.now()` right after `client.state = "connected"`, so the keepalive window starts when the client becomes connected                                                                                                                             |
| `DispatchGuard`              | the `vim.schedule`d `on_message` runs only `if client.state == "connected" and not client.tcp_handle:is_closing()`                                                                                                                                                                                     |
| `PeerCloseMarksClosing`      | on Claude's Close frame, `process_data` writes the reply Close frame, sets `state = "closing"` and schedules `on_close`                                                                                                                                                                                |
| `DisconnectOnce`             | `_disconnect_client` returns when `server.clients[client.id]` is gone, before `server.on_disconnect` and `_remove_client`                                                                                                                                                                              |
| `DisconnectClosesSocket`     | `_remove_client` clears `server.clients[client.id]` and calls `release_socket`, which closes the handle                                                                                                                                                                                                |
| `UnlistedDisconnectReleases` | `_disconnect_client` calls `release_socket(client)` before it returns for a client that is no longer in `server.clients`                                                                                                                                                                               |
| `CloseWriteOwnsSocket`       | `release_socket` returns without closing while `client.close_pending`. `close_client` sets it before it writes the Close frame, its write callback clears it and closes the handle, and the ping timer clears it before `_disconnect_client`, so a timed-out client does not wait for the write        |
| `RejectClosesSocket`         | the write callback of a rejected handshake calls `on_error`, then closes the handle if it is not closing                                                                                                                                                                                               |
| `ProtocolReportsAtOnce`      | each of the two protocol-error closes in `process_data` (a frame that `parse_frame` rejects, a data message that breaks the protocol) calls `fail_connection`, which runs `close_client(client, status, ...)` and then `on_error` without waiting for the Close write; `close_client` has no `on_done` |
| `StopWaitsForCloseWrite`     | `stop_server` only calls `close_client(client, 1001, "Server shutting down")`, and closes no handle itself: the Close write callback does                                                                                                                                                              |
| `KeepaliveReaps`             | the ping timer pings a connected client that `is_client_alive(client, interval * 2)`, and otherwise calls `close_client(client, 1011, ...)`, then `_disconnect_client(server, client, 1006, ...)`                                                                                                      |
| `DropsOnSecondOverdueTick`   | in the ping timer, a client that is not alive and has no `pong_overdue` gets a ping and `client.pong_overdue = true`, and only a client that already has `pong_overdue` is closed with 1011                                                                                                            |
| `AliveTickClearsOverdue`     | in the ping timer, a client that is alive gets `client.pong_overdue = nil` before its ping                                                                                                                                                                                                             |
| `PongResetsAge`              | a PONG frame sets `client.last_pong = vim.loop.now()`                                                                                                                                                                                                                                                  |
| `WakeResetsPong`             | after a tick gap above `interval * 1.5`, the ping timer sets `last_pong = now` for each client in state `connected`, and it sets `last_run = now` each tick                                                                                                                                            |

On `BROKEN`, the script prints the TLC trace as action names. Each action of `model/WsConnection.tla` names the file and function it models. Read the trace with the pstack `/statechart` skill:

1. Rerun with `--keep`.
2. Copy the broken run's `.cfg` from the kept dir. Lower `PeerBudget` to 1 (only the upgrade request), then raise it only while the rule stops breaking. Set `MaxSleeps` to 0 unless the path needs a delayed tick (a gap or a late tick). Stop at the smallest config that still breaks the rule. Delete the kept dir when you are done.
3. Give `/statechart` the kept `WsConnection.tla`, that cfg, and the view `model/statechart-view.ts`.

The report tells the path in plain words, for example "Claude connects, the ping timer ticks after Neovim was blocked, the plugin reads its upgrade request, the 101 reply is written, the ping timer drops Claude for no reply". That is the `NoFalseTimeout` finding below.

Then decide which kind of failure it is:

- **Real bug.** A fact went `FALSE` because the change removed or moved a guard, or a fixed finding's path is open again, and the code can take the path. Replay it on the real code (see `replays/`) before you report it, and report it in the code's words. Never weaken a rule or the model to make it pass.
- **Modeling error.** The facts are `TRUE` but the path needs a step the code cannot take, or a fact reads `FALSE` because the guard was reworded and still works (for example `if not (client.state == "connected") or ...`). Fix the regex or the model, run `--mutants`, and say what you changed.

`--mutants` removes each guard alone and checks each rule alone: each fact must break the rule its `EXPECT` entry names, and each rule must break at least once. The environment steps of the bugs this model found (`GapDuringHandshake`, `WindowFullOnProtocolClose`, `StopBeforeOnClose`, `LateTickAfterPing` and `ExactBoundaryTick` in the model) stay on in every run.

## Bugs this model found

The first run of this model broke three rules on the code as it was. Each one was replayed on the real code, and PR #455 fixed all three. A review of this skill's own PR then found a fourth, which the first model could not see, and PR #479 fixed it.

- **`NoFalseTimeout`.** The ping timer's wake reset touched only `connected` clients, so a Neovim main loop that blocked for more than `interval * 1.5` between the accept and the handshake left the new client with the `last_pong` that `create_client` set at the accept. The timer then dropped a Claude that answered every ping, one interval after its handshake, before any ping reached it. The 101 write callback now sets `last_pong` (`UpgradeStartsKeepalive`).
- **`DeadClientDropped`.** After a protocol error `close_client` queued its Close frame and left `on_error` to the write callback, which runs only once Claude reads again. A Claude with a full receive window kept its client in `server.clients`, `is_claude_connected()` returned `true`, and `on_disconnect` (the diff cleanup) did not run. `process_data` now reports the client at once (`ProtocolReportsAtOnce`). `client.close_pending` keeps `_remove_client` from closing the socket while the Close frame waits, so the frame is still delivered (`CloseWriteOwnsSocket`).
- **`DroppedSocketCloses`.** A server that stopped after Claude's Close frame was read and before the scheduled `on_close` ran dropped the client from `server.clients`, and nothing closed its socket: it stayed in `CLOSE_WAIT`. `_disconnect_client` now closes the socket of a client that is no longer listed (`UnlistedDisconnectReleases`).
- **`NoFalseTimeout`, again.** The first model advanced each ping-timer tick by exactly one interval. A tick that Neovim ran late after a block of 1.0 to 1.5 intervals is below the wake threshold (`interval * 1.5`), so `last_pong` was not reset, and the tick can run before the plugin reads Claude's pong: on Neovim 0.8 after any block, and on newer Neovim after a block inside a libuv callback that runs after the poll phase, such as a check callback. The tick then found the last pong 2.3 intervals old and dropped a Claude that answers every ping. The first tick that finds no pong for two intervals now pings again and sets `pong_overdue`, and only the second drops the client (`DropsOnSecondOverdueTick`, `AliveTickClearsOverdue`). The model has the step `TimerTicksLate` (`LateTickAfterPing`) for it.

## Replays

A replay runs one of these scenarios on the real code, in a headless Neovim with real sockets, the real ping timer at a short interval, and `vim.schedule`. Only Claude is played, by a luv TCP client in the same Neovim (`replays/harness.lua`). Each replay checks the promise that the fix keeps. Run one from the repo root:

```bash
.agents/skills/verify-ws-connection/replays/run.sh <replay>.lua   # NVIM=/path/to/nvim overrides; about 1 to 3 s
```

It prints one `KEPT` or `BROKEN` line per check and a count line, and exits 0 only when every check is kept. A check that the host cannot run prints `SKIPPED` and counts as neither kept nor broken: the kernel-state check of `stop-before-on-close.lua` reads `/proc/net/tcp`, so it prints `SKIPPED` on macOS and BSD, and the `is_closing()` check above it still decides. The replays run on Neovim 0.8 and newer, because `run.sh` starts them with `-c`, not `-l`.

| Replay                           | Scenario                                                                                                                                                                                | Promise                                                                                                                                                                                                                                                        |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gap-during-handshake.lua`       | The loop blocks for 700 ms (interval 200 ms) right after the accept, before the read of the upgrade request.                                                                            | A Claude that answers every ping is pinged, gets no Close frame, and stays listed for 10 intervals.                                                                                                                                                            |
| `short-block-after-ping.lua`     | One main-loop block of 1.3 intervals (interval 200 ms) starts right after a ping, in a libuv check callback, so the next tick runs before the socket read. Then Claude stops answering. | A Claude that answers every ping is not dropped by the late tick, and stays listed for 1500 ms. A Claude that stops answering is still dropped, with Close 1011.                                                                                               |
| `protocol-close-window-full.lua` | Claude stops reading, the plugin fills its window with 4 MiB messages, and Claude sends a binary frame.                                                                                 | The client is gone from `server.clients`, reported once, and not counted by `is_claude_connected()` while Claude does not read. Its socket stays open for the Close frame, which Claude gets (1003) once it reads, and then the socket closes.                 |
| `stop-before-on-close.lua`       | A libuv check handle calls `server/init.lua` `M.stop` in the same loop turn as the read of Claude's Close frame, before `on_close` runs.                                                | The stop reports no client (`M.stop` rejects the pending diffs itself), and the socket closes: `is_closing()` is true and the kernel does not hold it in `CLOSE_WAIT`. The replay does not show that a typed `:ClaudeCodeStop` can land in that one loop turn. |

`VimLeavePre` also stops the server, but Neovim exits right after.

## Update after an intended change

1. Read every `was:`/`now:` line of the STALE output and the code behind it.
   - If only `file` lines changed, and the change cannot reach a client's state, its socket, `server.clients`, the ping timer or the server stop (for example a terminal or diff change in `init.lua`), say so in the PR. Then skip to step 4.
2. If the behavior changed, change the action in `model/WsConnection.tla` that cites that code. If a guard moved, change its fact regex in `check.sh`. If a guard is new, add a fact and its `EXPECT` entry. 3. Run `check.sh --mutants`. Every fact must be caught by its rule, and every rule must break at least once.
3. Run `check.sh` and read the result.
4. Run `check.sh --record` only once you have confirmed that the model describes the code at this commit. Commit `covered.lock` with the change.

## Scope and bounds

- One connection. Clients share only `server.clients` and the loops of the ping timer and `stop_server`, which treat each client alone. Client ids, the diffs a client owns, and the answers to its `openDiff` calls are checked by `verify-diff-lifecycle`.
- The safety rules run with Claude sending 3 frames, its upgrade request included (pongs and the hang-up come on top), and two delayed ticks (a gap above 1.5 intervals, or a late tick): about 176,000 states. The liveness rules run with 2 frames and no delayed tick: 5,946 states each.
- Writes follow libuv. A write goes into the kernel at once when nothing waits in libuv's queue and Claude's window has room. Its callback runs in a later step. Claude's window fills only when the plugin sends a large message while Claude does not read (`PluginSendsLarge`). When Claude reads again, libuv writes the whole queue in one step: the short gap between Claude making room and libuv's next write is not modeled. `uv_close` cancels what waits in the queue and runs the pending callbacks when the close finishes.
- One read carries one frame. `process_data` stops after a Close frame or a protocol error, and drops the bytes of a closing client, so a read of several frames reaches no other state.
- Every plugin step (reads, write callbacks, closes, scheduled callbacks, timer ticks) is fair. Claude is never assumed to act. `DroppedSocketCloses` alone assumes that Claude reads again (`PeerEventuallyReads`). Delayed ticks are bounded (`MaxSleeps`), so the timer cannot skip forever. Whether Claude's pong is read before a delayed tick depends on where the block ran, so the model lets both happen. A block shorter than one interval cannot leave the pong unread at the next tick: the loop reads the socket first. `is_client_alive` needs `now - last_pong` below two intervals, so a last pong that is exactly two intervals old is not alive. The loop time has a resolution of 1 ms, and a pong read in the same millisecond as the tick before it makes the second tick after it find exactly that. A normal tick finds the client alive in the model, and `ExactBoundaryTick` lets that tick find the client overdue instead, so a timeout change at the boundary does not pass for lack of the case.
- Not in the rules, on purpose:
  - The keepalive Close frame (1011). `server/README.md` documents that a Claude whose window is full does not get it, because `_disconnect_client` closes the socket right after `close_client` queues it.
  - The reply to Claude's Close frame. The code makes no promise about it, and it is lost the same way when Claude's window is full.
  - A connection that never finishes its handshake. The ping timer checks only `connected` clients, so a TCP connection that never sends its upgrade request stays in `server.clients` until it hangs up. No code or doc promises otherwise.
- Not modeled: frame encoding and parsing (`server/frame.lua`, unit tests), fragmented messages, Claude's own pings (the PONG reply is a write with no callback), the HTTP checks of `handshake.lua` (the model only knows "accepted" or "rejected"), deferred responses and diffs, the mention queue that `on_open` starts once a client's handshake completed (it only schedules `process_mention_queue`, and touches no client, socket or timer), the lock file, port selection, a restart (old clients keep the old server object, whose `clients` table is empty), and two servers in one Neovim.
- Not facts: the closing checks at the top of `process_data` and in its frame loop. Removing one alone breaks no rule, because `DispatchGuard` and `DisconnectOnce` also stop what follows.
- A pass covers this model at these bounds, for the facts `check.sh` reads, on the covered files exactly as recorded in `covered.lock`. Any other tree reads STALE.
