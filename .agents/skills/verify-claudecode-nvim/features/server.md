# Start and stop the Claude server

claudecode.nvim runs a WebSocket server on `127.0.0.1` and writes a lock file, `$CLAUDE_CONFIG_DIR/ide/<port>.lock` (or `~/.claude/ide/<port>.lock`), that gives the Claude CLI the port and an auth token. The server starts with Neovim by default and stops when Neovim quits. The user stops, starts, and checks it with `:ClaudeCodeStop`, `:ClaudeCodeStart`, and `:ClaudeCodeStatus`. A client without the lock file's token is refused. When a Claude client disconnects, or the server stops, the diffs still waiting for an answer close.

## Sub-features

- `server-status` `:ClaudeCodeStatus` prints `Claude Code integration is running on port <port>` or `Claude Code integration is not running`.
- `server-lock` the lock file is mode `0600` in a `0700` folder and holds nvim's `pid`, `ideName` `Neovim`, `transport` `ws`, the cwd in `workspaceFolders`, and a 32-character hex `authToken`.
- `server-stop` `:ClaudeCodeStop` deletes `<port>.lock`, answers each pending openDiff with `DIFF_REJECTED`, closes each client with code 1001, and prints `Claude Code integration stopped`.
- `server-start` `:ClaudeCodeStart` listens on a new random port, writes a new lock file with a new token, and prints `Claude Code integration started on port <port>`.
- `server-twice` Start while running warns `Claude Code integration is already running on port <port>`. Stop while stopped warns `Claude Code integration is not running`.
- `server-exit` quitting Neovim deletes the lock file.
- `server-auth-refuse` a client whose `x-claude-code-ide-authorization` header does not match gets no connection, and Neovim warns `Rejected client_<n>: Invalid authentication token`.
- `server-disconnect` when a client disconnects, its unanswered diffs close. Diffs of other clients stay open.

## How to get to it (user POV)

- Neovim starts the server in `setup()` when `auto_start` is true (the default), and stops it on exit.
- The user runs `:ClaudeCodeStart`, `:ClaudeCodeStop`, or `:ClaudeCodeStatus`.
- The Claude CLI reads the lock file, connects with its token, and drops the socket when it exits.

## Driving it with vcn.sh

Preconditions:

- Baseline launch with `hello.txt` open and `$V doctor` all `ok`. Run this recipe last: after Stop, the run cannot return to the baseline.
- In each bash call, also set `S=.agents/skills/verify-claudecode-nvim/scripts`, `L=$VCN_STATE/claude/ide`, and `M='split(execute("messages"), "\n")[-1]'`, the last `:messages` line. Wait for each message with `$V until "$M" '<line>'`.

Steps:

- **Status and lock file.** Run `$V keys ':ClaudeCodeStatus' Enter` and `$V until "$M" "[ClaudeCode] [command] [INFO] Claude Code integration is running on port $PORT"`. `stat -c %a "$L" "$L/$PORT.lock"` prints `700` and `600`. `jq -c '{pid,ideName,transport,workspaceFolders}' "$L/$PORT.lock"` prints `{"pid":<NVIM_PID>,"ideName":"Neovim","transport":"ws","workspaceFolders":["<WORK>"]}`. Save the token hash with `jq -j .authToken "$L/$PORT.lock" | sha256sum > "$OUT/server-token-1.sha"`.
- **Refuse a wrong token.** Forge a lock file for the same port outside `$L`: `mkdir "$OUT/forged" && jq -n '{authToken:"0123456789abcdef0123456789abcdef"}' > "$OUT/forged/$PORT.lock"`. Run `timeout 10 "$NODE_DIR/node" "$S/ws-client.mjs" "$OUT/forged/$PORT.lock" /dev/null "$OUT/ws-in-forged.jsonl" 2> "$OUT/ws-client-forged.log"; echo "exit $?"`. It prints `exit 1`, the log ends with `ws-client: closed (code 1006)`, and `$OUT/ws-in-forged.jsonl` does not exist. `:messages` holds `[ClaudeCode] [client] [WARN] Rejected client_2: Invalid authentication token`, and `$V doctor` stays all `ok`.
- **Disconnect closes that client's diffs.** Open a diff as the launch client with id `s1` and tab `✻ [Claude Code] hello.txt (s1) ⧉`, and wait for its proposal. Run `VCN_CLIENT=b $V connect`, open a diff as `b` for `other.txt` with id `b1` and tab `✻ [Claude Code] other.txt (b1) ⧉`, and `$V until "tabpagenr('\$')" 2`. Run `$V capture server-disconnect-before`, `VCN_CLIENT=b $V disconnect`, and `$V until "tabpagenr('\$') . winnr('\$')" 12`. `$V expr 'bufname()'` ends with `(s1) ⧉ (proposed)`, and `$V await s1 2` exits 1. Run `$V capture server-disconnect-after`.
- **Stop.** Run `$V keys ':ClaudeCodeStop' Enter` and `$V until "$M" '[ClaudeCode] [init] [INFO] Claude Code integration stopped'`. `$V await s1` prints `DIFF_REJECTED`, `$V until "tabpagenr('\$') . winnr('\$') . bufname()" 11hello.txt` passes, `ls -A "$L"` prints nothing, and `tail -n 1 "$OUT/ws-client.log"` prints `ws-client: closed (code 1001)`. Run `$V screenshot server-stopped`.
- **Stopped state.** `:ClaudeCodeStatus` prints `[ClaudeCode] [command] [INFO] Claude Code integration is not running`. `:ClaudeCodeStop` prints `[ClaudeCode] [init] [WARN] Claude Code integration is not running`.
- **Start.** Run `$V keys ':ClaudeCodeStart' Enter`, `$V until 'len(glob($CLAUDE_CONFIG_DIR . "/ide/*.lock", 0, 1))' 1`, and `NEW=$(basename "$L"/*.lock .lock)`. `$V until "$M" "[ClaudeCode] [init] [INFO] Claude Code integration started on port $NEW"` passes, `jq .pid "$L/$NEW.lock"` prints `$NVIM_PID`, and `jq -j .authToken "$L/$NEW.lock" | sha256sum | cmp -s - "$OUT/server-token-1.sha"` exits 1. A second `:ClaudeCodeStart` prints `[ClaudeCode] [init] [WARN] Claude Code integration is already running on port $NEW`.
- **Exit.** Run `$V record server`, then `$V keys ':qa!' Enter`. `timeout 5 bash -c 'while [[ -e $1 ]]; do sleep 0.1; done' _ "$L/$NEW.lock"` exits 0.
- **Proof.** Keep the two `server-disconnect` captures, `server-stopped.png`, `ws-in.jsonl`, `ws-client.log`, and `ws-client-forged.log`.

## Gotchas

- After Stop the launch client is gone and `$V doctor` fails its client and server lines. `$V connect`, `$V tool`, and `$V doctor` keep the old `PORT` from `run.env`, and Start picks a new port and token, so no harness client can reach the restarted server.
- vcn.sh has no bad-token command: `connect` always reads the run's real lock file. Never write the forged file into `$L`, where it would replace the real lock file.
- `$V disconnect` sends SIGTERM, so the plugin reads a clean close. A TCP reset is not covered.
- Stop and disconnect close only unanswered diffs. A diff the user accepted with `:w` stays open (see [close-diffs](./close-diffs.md)).
- `:ClaudeCodeStatus` reports only the server, not whether Claude is connected.
