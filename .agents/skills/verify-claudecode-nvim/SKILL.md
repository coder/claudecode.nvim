---
name: verify-claudecode-nvim
description: Drive the real claudecode.nvim plugin in a real Neovim (an agent-tty terminal) while a scripted WebSocket client (scripts/ws-client.mjs) plays the Claude Code CLI over the plugin's WebSocket MCP server, and capture screen text, PNG screenshots, WebM video, JSON-RPC traffic, and file state as evidence. Use to prove a claudecode.nvim feature works end to end (openDiff accept/reject, openFile, selection tracking, :ClaudeCodeSend at-mentions, closing diffs, the Claude terminal commands, the editor-state tools, server start/stop) without the claude CLI or network. Also use it to reproduce a bug report, and for any change that can raise a prompt or change the editor mode.
---

# Verify claudecode.nvim

The user surface is Neovim plus the Claude Code CLI. This skill keeps Neovim real: an [agent-tty](https://github.com/coder/agent-tty) terminal session, keystrokes through `agent-tty type` and `send-keys`, state read over Neovim RPC. Only the CLI is replaced, by `scripts/ws-client.mjs`, at the boundary the CLI uses: it reads the lock file the plugin writes (the token stays out of argv), sends the `x-claude-code-ide-authorization` header, and speaks MCP JSON-RPC.

Each run gets its own HOME, XDG dirs, `CLAUDE_CONFIG_DIR`, agent-tty home, and nvim socket. Runs never touch the user's Neovim or `~/.claude/ide`, and two runs can go side by side.

Needs:

- `nvim` 0.12.3, `jq`, and Node 26, all from `mise install`. `VCN_NVIM` runs another Neovim, 0.8 or newer (see Launch).
- `agent-tty` 0.5.0 (`npm install -g agent-tty`). It needs Node 24 to 26, so the harness runs it on the repo's mise Node. Launch keeps the first agent-tty that passes `agent-tty doctor` (see `VCN_AGENT_TTY`).
- Playwright Chromium for PNG and WebM: `npx playwright install chromium`.
- `setsid` from util-linux. Launch resolves `jq` and `setsid` once, through mise first, and every call uses that path, so a failing `jq` or `setsid` earlier on `PATH` does not break the run or its teardown.
- `perl`, for `scripts/proof-agent-tty-resolution.sh`. It resets SIGINT and SIGHUP before it starts launch, because bash cannot trap a signal that was ignored at entry.

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

Launch first runs `agent-tty doctor` and saves it to `$OUT/agent-tty-doctor.json`. Launch keeps the first agent-tty that passes (see `VCN_AGENT_TTY`). When none passes, it stops and names each candidate and its failed check, such as the Node version, `pty.node`, or the Chromium launch. Launch then returns only when the run is usable: nvim answers RPC, the plugin wrote `<port>.lock` naming the nvim pid, the client finished the handshake, and the MCP `initialize` call answered with a result. If a step misses its 10 s deadline, or `initialize` answers without a string `result.protocolVersion`, launch saves `$OUT/launch-failure.screen.txt`, tears the run down, and exits 1. Once launch has made its state dir, SIGTERM, SIGINT or SIGHUP tears the run down too, and launch exits 143. That teardown saves no evidence (no final screen, PNG or WebM), because those take long on a loaded host. Launch picks it by whether a signal reached launch, not by the status 143. A launch that fails by itself takes the full teardown and saves its evidence, and so does a launch whose child someone else killed with SIGTERM, because no signal reached launch. Its exit status is 143 when launch ran the killed command itself (the `cp` of `run.env`), and 1 when the killed command is an agent-tty call that launch checks, such as `create`. A signal that reaches launch after the teardown of a failure of its own has started changes nothing: launch exits 1 and keeps the evidence, the saved failure screen included. A signal that reaches launch before that teardown has started, even in the microseconds after the failure, counts as a signal: the signal trap runs the fast teardown itself, and launch exits 143 with its `vcn: launch failed` line. A teardown ignores a second signal until it ends. Launch's own shell ignores it, but Node resets an ignored signal when it starts, so a signal sent to launch's process group would kill `agent-tty home forget` and leave the home in `~/.local/state/agent-tty/homes.json`. The teardown therefore starts every agent-tty call it makes (the evidence steps, `destroy` and `home forget`) in its own session (`setsid`), where that signal does not reach it. It also removes the socket directory `/tmp/agent-tty/<8 hex digits of the sha256 of the real path of $VCN_STATE/att>` that agent-tty makes at its first call, even when the signal came before `inspect` named it. agent-tty hashes the real path of its home, so a symlink in `TMPDIR` changes the name, and the cleanup resolves it the same way. A signal before launch sets its first trap ends launch with the default status (130 for SIGINT, 129 for SIGHUP, 143 for SIGTERM) and leaves nothing behind. A signal from then until the state dir exists is recorded: launch removes the dir and exits 143 for all three. Launch prints `VCN_STATE=` before it stops handling signals, so a signal never leaves a running run whose name was not printed.

- Seed files in `$WORK` (nvim's cwd and the workspace folder): `hello.txt` is `alpha`, `beta`, `gamma`. `other.txt` is `one`, `two`, `three`, `four`.
- The terminal is 160 columns by 40 rows.
- `VERIFY_OUT=<dir>` sets the evidence dir. It must be missing or an empty directory, and its path must not have a `.` or `..` part. Launch refuses it if it is a symlink, is not a directory, is owned by another user, or is group- or world-writable, or if a dir above it is unsafe (see Evidence). It also refuses a path that `mkdir` cannot create. When another launch makes a missing dir above the evidence dir first, launch uses that dir, and the check after `mkdir` decides whether it is safe. When it refuses a dir after `mkdir`, it runs `rmdir` on each dir that it made itself. That never deletes a file, a non-empty dir, or a dir that another process made. Launch creates a missing evidence dir, and each missing dir above it, with mode `0700`, so a default ACL on a parent never gives the group access to them. It removes any ACL, default ACLs included, from the evidence dir and from each dir above it that it made, with `setfacl -b -k`, and makes the evidence dir `0700`, and it refuses the dir when a new file there still does not get mode `0600`, for example under a default ACL with no working `setfacl`. A relative path is taken from the current directory and recorded as an absolute `OUT`.
- `VCN_AGENT_TTY=<path>` runs that agent-tty, and only that one. Without it, launch runs `agent-tty doctor` on each `agent-tty` on `PATH`, then on `mise which agent-tty`, and keeps the first that passes, so an agent-tty on `PATH` wins over mise's. A mise-installed `npm-agent-tty` can lack node-pty's native build, and then every command dies with `Failed to load native module: pty.node`. When no candidate passes, launch exits 1 with one message that lists each candidate's failure and the fix, which leaves mise's install alone: `npm install --prefix <dir> agent-tty@0.5.0`, then `VCN_AGENT_TTY=<dir>/node_modules/.bin/agent-tty $V launch`. That is enough: with `VCN_AGENT_TTY` set, launch never looks at `PATH` or mise for agent-tty, so mise's broken copy does not matter and `MISE_DISABLE_TOOLS` is not needed.
- `VCN_NVIM=<path>` runs that Neovim binary instead of the repo's mise `nvim`, for example a release tarball's `bin/nvim` to check Neovim 0.8. The harness uses it for its RPC calls too. On Neovim 0.8, one process is both the TUI and the server that answers RPC, so doctor checks that the server pid is the session's TUI pid. Neovim 0.8 prints a `--remote-expr` result on stderr, so on 0.8 `$V expr` prints an error message as its output, where 0.9+ prints it on stderr.
  - CI does not run the harness, on 0.8 or any other version. A run needs `agent-tty` from npm and Playwright Chromium (about 400 MB unpacked), and CI installs neither. Node is not the obstacle: the `unit-tests` job already gets the repo's Node 26 from mise. The two would add minutes and two more downloads to every PR. CI's `integration-tests (v0.8.0)` job already runs the plugin's integration tests on Neovim 0.8. After a change to `vcn.sh`, check the 0.8 path by hand: do the full run at the end of this file, with `VCN_NVIM=<0.8 nvim> $V launch` as its launch step.
- `VCN_RTP=<dir>[:<dir>...]` adds plugin dirs to `runtimepath` after this checkout. A `terminal.provider = "snacks"` run needs a snacks.nvim clone there, because the harness installs no plugin. Pin the clone as [features/send-at-mention.md](features/send-at-mention.md) shows. A relative entry resolves against the directory you launch from, because nvim runs in `$WORK`, and symlinks are followed. Launch exits 1 for an entry that is not a directory, so a typo cannot pass as a snacks run on a native terminal. A float run is in [features/terminal-float-diff.md](features/terminal-float-diff.md).
- `VCN_INIT_JSONRPC=<version>` sets the `jsonrpc` field of the `initialize` request (default `2.0`). Only `scripts/proof-launch-refusals.sh` sets it, to get an error answer from the plugin.
- `TMPDIR=<dir>` makes launch put its state dir, `vcn.XXXXXX`, in `<dir>` instead of `/tmp`. The path must be absolute and name an existing directory (a missing one could be made by another user after the checks). Launch refuses a `TMPDIR` that another user could write: `<dir>` or a dir above it is owned by another user (root is fine) or is group- or world-writable without the sticky bit. `/tmp` is sticky, so the default passes. Keep it short: nvim's socket, `nvim.sock`, lives in the state dir, and a Unix socket path is limited to 108 bytes. Neovim 0.12.3 accepts a longer path. Older versions are untested. `cleanup` accepts a state dir from any `TMPDIR`: an absolute path that ends in `/vcn.` and six letters or digits. Every command that reads a run refuses a `run.env` that is a symlink or owned by another user, because it sources that file. A run that an older `vcn.sh` started has no `JQ_BIN` in `run.env`, so the command resolves `jq` again. `scripts/proof-agent-tty-resolution.sh` runs every launch with a private `TMPDIR`.
- `VCN_SETUP='<json>'` is deep-merged into `require("claudecode").setup()` over the base `{ terminal = { provider = "none" } }`. Example: `VCN_SETUP='{"diff_opts":{"layout":"unified"}}' $V launch`.
- For a `log_level = "debug"` run, launch with `VCN_SETUP='{"log_level":"debug"}' $V launch --cmd 'set messagesopt=wait:0,history:10000' hello.txt`. Without it, one openDiff call at debug level parks Neovim at `Press ENTER`, and RPC stops answering. Launch arguments replace the default file, so name `hello.txt`. Neovim 0.8 has no `messagesopt`, so plain `set` fails launch with E518. Use `--cmd 'silent! set messagesopt=wait:0,history:10000'` there. Launch then works, but debug echoes still stop at `Press ENTER` (see Doctor).

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
- To watch live, a human runs `source "$VCN_STATE/run.env"; PATH="$NODE_DIR:$PATH" "$ATT_BIN" --home "$ATT_HOME" dashboard --session "$SID"` in a terminal. The dashboard is read-only and leaves the session size alone.
- agent-tty answers no DA1 (`ESC[c`) query. Neovim 0.12's TUI stops a `:suspend` only when the terminal answers its DA1 query, so in this harness `:suspend` and Ctrl-Z fire `VimSuspend` and detach the UI, but the TUI process never stops (state `S`, not `T`) and the screen stops updating while nvim keeps taking keys. Count `VimSuspend` events, and read buffer text through `$V expr`, instead of watching the process state or the screen.

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
- Proves a change that can raise a prompt or change the editor mode in a live run. After the call, it types the user's next keys with `$V keys` and checks the buffer text. A headless `nvim -u NONE` run answers a file-changed dialog at once with its default choice and hides the bug. Before #408, headless openFile kept the user's unsaved text, while live the W13 dialog (the file appeared after its buffer was opened) held the reply and the user's next `l` loaded the file over that text.

## Cleanup

```bash
$V cleanup
```

Cleanup saves the final screen text, a PNG, `:messages`, and a WebM of the whole session into `$OUT`. Then it destroys the agent-tty session, which ends nvim, and stops the client by its recorded PID. It waits for every process tagged `VCN_RUN_TAG=$VCN_STATE` to exit, and after 3 s kills only those. Then it drops the run's agent-tty home from the per-user home registry, removes its empty socket directory under `/tmp/agent-tty`, deletes `$VCN_STATE`, and leaves `$OUT` alone. It takes 10 to 15 s. Rerunning it prints `nothing to clean`. Run it after every failed iteration too.

To confirm, `grep -lzxF "VCN_RUN_TAG=$VCN_STATE" /proc/[0-9]*/environ 2>/dev/null` prints nothing (the `2>/dev/null` hides other users' unreadable processes). Never `pkill` by name or by `-f` pattern: other agents' nvim and agent-tty hosts run on the same host, and a `-f` pattern can match your own shell.

## Helpers

- `scripts/vcn.sh` is the harness. `$V help` lists its subcommands.
- `scripts/init.lua` is the nvim config. It puts this checkout first on `runtimepath`, appends each `VCN_RTP` dir, sets `terminal.provider = "none"` so no `claude` CLI starts, and merges `VCN_SETUP`.
- `scripts/proof-agent-tty-resolution.sh` proves how launch picks an agent-tty and loads `VCN_RTP`, with stand-ins for a broken agent-tty and for mise: launch skips an agent-tty that fails `agent-tty doctor`, `VCN_AGENT_TTY` wins, launch exits 1 with the fix message when none passes, `require()` finds a module in each `VCN_RTP` dir, `vcn.sh` has no `jq` or `setsid` command except through `$JQ_BIN` and `$SETSID_BIN` (the proof reads the source), a `run.env` without `JQ_BIN` still runs `jq`, a symlinked `run.env` is refused, a symlink in `TMPDIR` does not leave the socket dir, SIGTERM to a running launch leaves no state dir or process, a second signal does not stop the teardown (a Node stand-in for `agent-tty home forget` finishes), a storm of signals leaves no run behind, the socket directory that agent-tty made is removed, a child killed from outside gets the full teardown, a signal during the failure screen of a launch that failed by itself leaves exit 1 and a screen with text, a signal before the teardown of such a failure has started gets the fast teardown, `cleanup` removes a run that has no agent-tty, the proof never reads or cleans a `/tmp/vcn.*` dir that it did not start, because it runs every launch with a private `TMPDIR`. It starts real runs, so it needs everything under Needs. It prints `ok <case>` per case and ends with `CASES <n>`, or prints `FAIL <case>: <reason>` and exits 1.
- `scripts/proof-launch-refusals.sh` proves that launch exits 1 and leaves no run behind when `initialize` fails (it sends `jsonrpc` `1.0` and the plugin answers -32600), and when `VERIFY_OUT` or the default parent dir is unsafe or cannot be created, and when `TMPDIR` or a dir above it is world-writable and not sticky, or `TMPDIR` does not exist. It also proves that a sticky `TMPDIR` is accepted. It also proves that a refused launch leaves the proof's temp dir as it found it, and that a relative `VERIFY_OUT` that starts with `-` works. It prints `PASS <case>` per case or `FAIL: <reason>`. It takes about 60 s.
  - The `out-dash`, `out-acl`, `out-made` and `init` cases start a real run, so they need everything under Needs, including Playwright Chromium for the user who runs the proof. Without it, `out-dash` fails at `agent-tty doctor`.
  - The `out-acl-unremovable`, `out-acl` and `out-made` cases need `setfacl` and a filesystem with default ACLs. Without them, the proof prints `SKIP` for all three. `out-acl` checks that every evidence file of a run in a `0500` dir with a default ACL is `0600`. `out-made` checks that launch creates a new `VERIFY_OUT` two levels below a dir with a default ACL, makes both new dirs `0700` with no ACL left on either, and that every evidence file is `0600`.
  - The `race` case puts a `mkdir` shim first on `PATH`. The shim plays another launch that makes the dir above `VERIFY_OUT` first, group-writable. Launch must refuse that dir in the check after `mkdir` and leave it in place.
  - The `init` case writes its evidence, with `init-refusal-launch.txt`, to a fresh `mktemp -d` dir. The proof deletes that dir when every case passes. When the `init` case fails, the proof keeps it and prints `init evidence kept in <dir>`. Delete it when you are done.
- `scripts/fake-terminal.sh` is a `terminal_cmd` that prints a banner and sleeps, so a plugin-managed terminal runs without the `claude` CLI.
- `scripts/observe-windows.lua` prints the window state as JSON (focus, mode, rectangles, floats, how many cells of each diff window a float covers). Run it with `$V expr "luaeval('dofile(\"<path>\")')"`.
- `scripts/journey-snacks-float-reload.sh` proves that a float the user hid stays hidden after a plugin reload. It needs the same launch as the next script and prints `PASS snacks-float-reload` or `FAIL: <reason>`.
- `scripts/journey-snacks-float-diff.sh` proves the float terminal hides when a diff opens and stays hidden after `close_tab`. It needs the launch in [features/terminal-float-diff.md](features/terminal-float-diff.md) and prints `PASS snacks-float-diff <layout> <nokeep|keep>` or `FAIL: <reason>`.
- `scripts/proof-ctrl-z-suspend.sh native|snacks` proves that Ctrl-Z in the Claude terminal runs Neovim's `:suspend` and never reaches the Claude job (#194). It launches its own run with `scripts/ctrl-z-probe-job.mjs` as `terminal_cmd`, a raw-mode stand-in for the Claude CLI that logs each byte it reads. It then runs `scripts/proof-ctrl-z-stop.py`, which starts nvim as a foreground job of `bash -i` in a pty that answers the terminal queries, and checks that Ctrl-Z stops nvim, that `fg` resumes it, and that the job never reads 0x1a. agent-tty cannot show that stop, because it sends no reply to the query that nvim waits for. See [features/terminal-ctrl-z.md](features/terminal-ctrl-z.md).
- `fixtures/term-keys-windows.lua` and `fixtures/term-keys-quit.lua` hold the two Lua blocks of the README section "Leaving Terminal Mode in the Claude Terminal". The `term-keys` recipe in `features/terminal.md` loads these files with `:luafile`, compares them with the README by text (`cmp`), and never runs README text.
- `scripts/journey-opendiff-accept.sh` proves openDiff accept through `:w` on a fresh launch. It prints `PASS opendiff-accept` or `FAIL: <reason>` and writes `opendiff-accept-*` files to `$OUT`: screen text at each step, PNGs at open, after the edit, and after `:w`, a WebM, and the file's sha256 at each step.
- `scripts/journey-diff-close-save.sh [existing|new]` proves what a proposed diff leaves behind when the user runs `:wq`, `:x`, `ZZ`, `:w` twice, `:q`, `:b hello.txt` or `:e other.txt` in the proposal window, and sets a sign column of its own after the `:e`, for a launch in either layout. It prints one `ok:` or `FAIL:` line per check, then `PASS diff-close-save` or `FAIL: <count> of <total> checks failed`, and writes `diff-close-save-*` screen captures to `$OUT`. See [features/open-diff.md](features/open-diff.md).
- `scripts/journey-new-tab-diff-mode.sh` proves that two diffs that open in new tabs leave the cursor in the proposal in Normal mode. It needs the launch in [features/open-diff.md](features/open-diff.md) (a real Claude terminal and `diff_opts.open_in_new_tab`), prints `PASS new-tab-diff-mode` or `FAIL: <reason>`, and writes `new-tab-diff-mode-*` screen captures to `$OUT`.

A full run, with the `VCN_STATE` value from launch:

```bash
V=.agents/skills/verify-claudecode-nvim/scripts/vcn.sh
$V launch
export VCN_STATE=/tmp/vcn.AbC123
$V doctor
.agents/skills/verify-claudecode-nvim/scripts/journey-opendiff-accept.sh
$V cleanup
```

## Real CLI handshake

This checks that the real Claude Code CLI accepts the plugin's WebSocket server. It registers the run's server in a scratch CLI config and asks the CLI for its status. Run it in any shell, with the `VCN_STATE` value launch printed in the first line:

```bash
export VCN_STATE=/tmp/vcn.AbC123
source "$VCN_STATE/run.env"
cfg=$(mktemp -d)
helper="jq -c '{\"x-claude-code-ide-authorization\": .authToken}' \"$VCN_STATE/claude/ide/$PORT.lock\""
json=$(jq -nc --arg u "ws://127.0.0.1:$PORT" --arg h "$helper" '{type: "ws", url: $u, headersHelper: $h}')
cli() { env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR="$cfg" claude "$@" </dev/null; }
cli mcp add-json -s user nvim "$json"
cli mcp get nvim | grep Status
rm -rf "$cfg"
```

`claude mcp get nvim` must print `Status: ✔ Connected`. A wrong token prints `Status: ✘ Failed to connect`. The CLI refuses to store `type: "ws-ide"`. The `headersHelper` reads the token from the `0600` lock file when the CLI connects, so the token stays out of argv, the CLI config, and the `mcp get` output. Checks never start the claude TUI or `claude -p` with host credentials.
