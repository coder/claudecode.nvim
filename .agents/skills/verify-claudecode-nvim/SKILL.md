---
name: verify-claudecode-nvim
description: Drive the real claudecode.nvim plugin in a real Neovim (an agent-tty terminal) while a scripted WebSocket client (scripts/ws-client.mjs) plays the Claude Code CLI over the plugin's WebSocket MCP server, and capture screen text, PNG screenshots, WebM video, JSON-RPC traffic, and file state as evidence. Use to prove a claudecode.nvim feature works end to end (openDiff accept/reject, openFile, selection tracking, :ClaudeCodeSend at-mentions, closing diffs) without the claude CLI or network.
---

# Verify claudecode.nvim

The user surface is Neovim plus the Claude Code CLI. This skill keeps Neovim real: an [agent-tty](https://github.com/coder/agent-tty) terminal session, keystrokes through `agent-tty type` and `send-keys`, state read over Neovim RPC. Only the CLI is replaced, by `scripts/ws-client.mjs`, at the boundary the CLI uses: it reads the lock file the plugin writes (the token stays out of argv), sends the `x-claude-code-ide-authorization` header, and speaks MCP JSON-RPC.

Each run gets its own HOME, XDG dirs, `CLAUDE_CONFIG_DIR`, agent-tty home, and nvim socket. Runs never touch the user's Neovim or `~/.claude/ide`, and two runs can go side by side.

Needs:

- `nvim` 0.12.3, `jq`, and Node 26, all from `mise install`.
- `agent-tty` 0.5.0 (`npm install -g agent-tty`). It needs Node 24 to 26, so the harness runs it on the repo's mise Node.
- Playwright Chromium for PNG and WebM: `npx playwright install chromium`.
- `setsid` from util-linux.

Run every command from the repo root. Read [features/README.md](features/README.md) before driving: it is the map of what to verify and how.

```bash
V=.agents/skills/verify-claudecode-nvim/scripts/vcn.sh
```

## Launch

```bash
$V launch            # opens hello.txt; `$V launch other.txt` opens the other seed file
```

Launch prints two lines, for example:

```text
VCN_STATE=/tmp/vcn.AbC123
OUT=/home/coder/.xum/sessions/<ws>/scratch/verify-claudecode-nvim/20261031T120000Z-AbC123
```

Every bash call is a fresh shell. Start each later call with the `VCN_STATE` value launch printed. Use a new request id for every `rpc` or `tool` call, because the harness refuses an id the run already used: `export VCN_STATE=/tmp/vcn.AbC123; source "$VCN_STATE/run.env"`. That also sets `OUT`, `WORK`, `PORT`, `SID` (the agent-tty session), and `NVIM_PID`.

Launch first runs `agent-tty doctor` and saves it to `$OUT/agent-tty-doctor.json`. A failed check, such as the Node version or the Chromium launch, stops the launch and names the check. Launch then returns only when the run is usable: nvim answers RPC, the plugin wrote `<port>.lock` naming the nvim pid, the client finished the handshake, and the MCP `initialize` call answered with a result. If a step misses its 10 s deadline, or `initialize` answers without a string `result.protocolVersion`, launch saves `$OUT/launch-failure.screen.txt`, tears the run down, and exits 1.

- Seed files in `$WORK` (nvim's cwd and the workspace folder): `hello.txt` is `alpha`, `beta`, `gamma`. `other.txt` is `one`, `two`, `three`, `four`.
- The terminal is 160 columns by 40 rows.
- `VERIFY_OUT=<dir>` sets the evidence dir. It must be missing or an empty directory, and its path must not have a `.` or `..` part. Launch refuses it if it is a symlink, is not a directory, is owned by another user, or is group- or world-writable, or if a dir above it is unsafe (see Evidence). It also refuses a path that `mkdir` cannot create. When it refuses a dir after `mkdir`, it runs `rmdir` on each dir that was missing before `mkdir`. That never deletes a file or a non-empty dir, but it does remove an empty dir that another process made at one of those paths in the meantime. Launch creates a missing evidence dir with mode `0700`, so a default ACL on its parent never gives the group access to it. It removes any ACL from the evidence dir with `setfacl -b -k` and makes it `0700`, and it refuses the dir when a new file there still does not get mode `0600`, for example under a default ACL with no working `setfacl`. A relative path is taken from the current directory and recorded as an absolute `OUT`.
- `VCN_INIT_JSONRPC=<version>` sets the `jsonrpc` field of the `initialize` request (default `2.0`). Only `scripts/proof-launch-refusals.sh` sets it, to get an error answer from the plugin.
- `VCN_SETUP='<json>'` is deep-merged into `require("claudecode").setup()` over the base `{ terminal = { provider = "none" } }`. Example: `VCN_SETUP='{"diff_opts":{"layout":"unified"}}' $V launch`.

## Doctor

```bash
$V doctor
```

Read-only. Prints one `ok` or `FAIL` line per check and exits 1 on any `FAIL`: agent-tty session running, nvim server running under the session's TUI process, the `ws-client.mjs` client alive, RPC answers as the recorded pid, nvim not stuck in a prompt, lock file names that pid, plugin server running on the lock port, lock `authToken` matches the server token (compared by sha256), a client finished the handshake. Run it first whenever a step misbehaves.

- A `FAIL` on the client or handshake line means the client died. Clean up and relaunch, because a new client cannot receive answers to calls the old one made.
- A `FAIL` on the RPC line usually means nvim waits at `Press ENTER`, where it answers no RPC. `$V expr` then prints `vcn: nvim RPC gave no answer in 5s`. `$V capture blocked` shows the message. Keep that capture as evidence, then `$V keys Enter` dismisses it.

## Drive

The user acts through keys. Claude acts through tool calls. Read state only to observe.

- **User.** `$V keys <arg>...` sends input to nvim, in order, as one `agent-tty batch`:

  | Argument                                                                                                                         | agent-tty step   | Examples                          |
  | -------------------------------------------------------------------------------------------------------------------------------- | ---------------- | --------------------------------- |
  | A key name: `Enter`, `Escape`, `Tab`, `Backspace`, `Space`, arrows, `Home`, `End`, `PageUp`, `F1`-`F12`, or `Ctrl+`/`Alt+` a key | `send-keys`      | `Enter`, `Escape`, `Ctrl+W`, `Up` |
  | Any other argument                                                                                                               | `type`, verbatim | `':w'`, `gg`, `cc`, `V`           |
  | Every argument after `-l`                                                                                                        | `type`, verbatim | `-l 'Enter the name'`             |

  So `$V keys ':3' Enter cc` types `:3`, presses Enter, and types `cc`. Key names match case-sensitively: `Enter` is a key, `enter` is text. tmux names such as `C-w` or `BSpace` are typed as text, so write `Ctrl+W` and `Backspace`.

- **Claude.** `$V tool <id> <toolName> '<arguments json>'` sends `tools/call`. `$V rpc <id> <method> '<params json>'` sends any request, for example `$V rpc t1 tools/list`. `$V await <id> [secs]` prints that response line or exits 1 after the timeout (default 10 s). Build arguments with `jq -nc --arg ...` so paths and newlines stay valid JSON.
- **A second Claude.** `VCN_CLIENT=b $V connect` starts one more client, named `b`, and finishes its handshake. Put `VCN_CLIENT=b` before `rpc`, `tool`, or `await` to act as `b`. Its messages land in `$OUT/ws-out-b.jsonl` and `$OUT/ws-in-b.jsonl`, and request ids are per client. `$V disconnect` kills the launch client by its recorded PID, the way an exiting Claude CLI drops its socket. `VCN_CLIENT=b $V disconnect` kills `b`.
- **Notifications.** The plugin pushes `selection_changed` and `at_mentioned` to the client. They land in `$OUT/ws-in.jsonl`: `jq -c 'select(.method == "at_mentioned")' "$OUT/ws-in.jsonl"`.
- **Observe.** `$V expr '<vimscript>'` evaluates over RPC. `$V until '<expr>' '<want>' [secs]` waits for a state instead of sleeping. Examples: `$V until "bufname() =~# ' (proposed)$'" 1`, `$V expr "join(getline(1, '\$'), '|')"`, `$V expr 'luaeval("vim.json.encode(require(\"claudecode.server.init\").get_status())")'`.
- **Capture.** `$V capture <name>` writes the screen text to `$OUT/<name>.screen.txt` and prints it. `$V screenshot <name>` writes `$OUT/<name>.png`. `$V record <name>` writes `$OUT/<name>.webm`, a video of the whole session from launch to now, sped up. All three first wait up to 5 s for the screen to stay unchanged for 300 ms.

Rules:

- Change state only through keys or tool calls. Calling plugin Lua over RPC to change state skips the path you are proving.
- openDiff answers only after the user acts. `$V await <id> 2` exiting 1 before the action is the proof that it blocks.
- After `Escape`, wait for `$V until 'mode()' n` before typing a `:` command.
- After `FILE_SAVED`, Claude writes the file itself: write `result.content[1].text` to disk, then call `close_tab`. The plugin never writes it.
- `$V until` confirms nvim state, not the screen. Use `$V capture` or `$V screenshot`, which wait for the screen, when the evidence is what the user sees.
- To watch live, a human runs `source "$VCN_STATE/run.env"; PATH="$NODE_DIR:$PATH" agent-tty --home "$ATT_HOME" dashboard --session "$SID"` in a terminal. The dashboard is read-only and leaves the session size alone.

## Evidence

Everything lands in `$OUT`, which cleanup never deletes. The default is `${XUM_SCRATCH_DIR:-/tmp}/verify-claudecode-nvim/<UTC time>-<id>`. The harness runs with `umask 077`, so `$OUT` is `0700` and its files are `0600`: they hold buffer text and accepted diffs. A default ACL on `$OUT` would override the umask, so launch removes it first (see `VERIFY_OUT`). Launch refuses a default parent dir (`${XUM_SCRATCH_DIR:-/tmp}/verify-claudecode-nvim`) that is a symlink, is owned by another user, or is group- or world-writable. It also refuses either dir when a dir above it, as given or as resolved, is owned by a user other than you or root, or is writable by others without the sticky bit. On a shared host, set `VERIFY_OUT` to a dir you own.

- `ws-out.jsonl` holds every JSON-RPC message the client sent. `ws-in.jsonl` holds every message it received, responses and notifications. A client from `connect` writes `ws-out-<name>.jsonl`, `ws-in-<name>.jsonl`, and `ws-client-<name>.log`.
- `<name>.screen.txt`, `<name>.png`, and `<name>.webm` come from `$V capture`, `$V screenshot`, and `$V record`.
- `run.env` records paths, PIDs, port, session id, and the nvim and agent-tty versions. It holds no auth token. `agent-tty-doctor.json` and `ws-client.log` sit next to it.
- Cleanup adds `final.screen.txt`, `final.png`, `messages.txt` (`:messages`), and `session.webm`.
- The `⧉` in diff tab names draws as an empty box in PNG and WebM, because neither agent-tty's fonts nor this host's fonts have that glyph. The `.screen.txt` file holds the real character.

A proof:

- Captures the screen text and a PNG before and after each user action, plus the response JSON, and ends with a WebM.
- Checks side effects directly: `sha256sum "$WORK/<file>"` before and after, buffer text through `$V expr`.
- Replaces nothing but the Claude CLI, and only at its WebSocket boundary. No stubbed plugin modules, no internal setters.
- Names the feature ID from `features/` and the entry point (key, command, or tool) next to each artifact it cites. A path that was not driven is reported as not verified, never covered by a different entry point.

## Cleanup

```bash
$V cleanup
```

Cleanup saves the final screen text, a PNG, `:messages`, and a WebM of the whole session into `$OUT`. Then it destroys the agent-tty session, which ends nvim, and stops the client by its recorded PID. It waits for every process tagged `VCN_RUN_TAG=$VCN_STATE` to exit, and after 3 s kills only those. Then it drops the run's agent-tty home from the per-user home registry, removes its empty socket directory under `/tmp/agent-tty`, deletes `$VCN_STATE`, and leaves `$OUT` alone. It takes 10 to 15 s. Rerunning it prints `nothing to clean`. Run it after every failed iteration too.

To confirm, `grep -lzxF "VCN_RUN_TAG=$VCN_STATE" /proc/[0-9]*/environ 2>/dev/null` prints nothing (the `2>/dev/null` hides other users' unreadable processes). Never `pkill` by name or by `-f` pattern: other agents' nvim and agent-tty hosts run on the same host, and a `-f` pattern can match your own shell.

## Helpers

- `scripts/vcn.sh` is the harness. `$V help` lists its subcommands.
- `scripts/init.lua` is the nvim config. It puts this checkout first on `runtimepath`, sets `terminal.provider = "none"` so no `claude` CLI starts, and merges `VCN_SETUP`.
- `scripts/proof-launch-refusals.sh` proves that launch exits 1 and leaves no run behind when `initialize` fails (it sends `jsonrpc` `1.0` and the plugin answers -32600), and when `VERIFY_OUT` or the default parent dir is unsafe or cannot be created. It also proves that a refused launch leaves the proof's temp dir as it found it, and that a relative `VERIFY_OUT` that starts with `-` works. It prints `PASS <case>` per case or `FAIL: <reason>`. It takes about 60 s.
  - The `out-dash`, `out-acl`, `out-made` and `init` cases start a real run, so they need everything under Needs, including Playwright Chromium for the user who runs the proof. Without it, `out-dash` fails at `agent-tty doctor`.
  - The `parent-made-unsafe`, `out-acl-unremovable`, `out-acl` and `out-made` cases need `setfacl` and a filesystem with default ACLs. Without them, the proof prints `SKIP` for all four. `out-acl` checks that every evidence file of a run in a `0500` dir with a default ACL is `0600`. `out-made` checks that launch creates a new `VERIFY_OUT` in a dir with a default ACL as a `0700` dir whose evidence files are all `0600`.
  - The `init` case writes its evidence, with `init-refusal-launch.txt`, to a fresh `mktemp -d` dir. The proof deletes that dir when every case passes. When the `init` case fails, the proof keeps it and prints `init evidence kept in <dir>`. Delete it when you are done.
- `scripts/journey-opendiff-accept.sh` proves openDiff accept through `:w` on a fresh launch. It prints `PASS opendiff-accept` or `FAIL: <reason>` and writes `opendiff-accept-*` files to `$OUT`: screen text at each step, PNGs at open, after the edit, and after `:w`, a WebM, and the file's sha256 at each step.

A full run, with the `VCN_STATE` value from launch:

```bash
V=.agents/skills/verify-claudecode-nvim/scripts/vcn.sh
$V launch
export VCN_STATE=/tmp/vcn.AbC123
$V doctor
.agents/skills/verify-claudecode-nvim/scripts/journey-opendiff-accept.sh
$V cleanup
```
