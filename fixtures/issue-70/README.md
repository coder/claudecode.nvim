# Issue #70 — "Sending files, current buffer, or lines to claude doesn't work"

> Source: https://github.com/coder/claudecode.nvim/issues/70
>
> Symptom: `[ClaudeCode] [queue] [ERROR] Connection timeout - clearing N queued @ mentions`

## The one fact behind every report

`:ClaudeCodeSend` (and the file/buffer/tree senders) call `send_at_mention`. When
Claude is not connected, the mention is **queued** and a `connection_timeout`
timer (default **10s**, `lua/claudecode/init.lua`) is armed. If Claude has not
opened a WebSocket back to the plugin's server by then, the queue is cleared with
the error above (`start_connection_timeout_if_needed`).

So the bug is never really "send is broken" — it is always **"the Claude CLI that
the plugin launched never connected back to the plugin's WebSocket server."** The
interesting part is _why_ Claude doesn't connect, and the issue thread contains
several distinct causes that all surface as this one error.

## How the plugin expects Claude to connect

1. The plugin starts a WebSocket server on `127.0.0.1:<port>` and writes
   `~/.claude/ide/<port>.lock` containing `{ pid, workspaceFolders, ideName:
"Neovim", transport: "ws", authToken }` (`lua/claudecode/lockfile.lua`).
2. The terminal provider launches Claude with `CLAUDE_CODE_SSE_PORT=<port>` and
   `ENABLE_IDE_INTEGRATION=true` in its environment (`lua/claudecode/terminal.lua`).
3. Claude reads `CLAUDE_CODE_SSE_PORT`, looks up the matching lock file for the
   auth token, and connects to `ws://127.0.0.1:<port>`.

## What was reproduced (claude 2.1.168, nvim 0.13, macOS)

Driven with the real `claude` CLI in a PTY (agent-tty) against the real plugin
server. A headless probe (`scripts/repro_issue_70_probe.lua`) reports whether
Claude actually opened a socket.

| #                   | environment                                         | result                                                                                                                         |
| ------------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **Baseline**        | `CLAUDE_CODE_SSE_PORT` set, no proxy                | **connects** (`client_count: 1`), `@` mention delivered                                                                        |
| **Proxy (the bug)** | `http_proxy`/`all_proxy` set, **no** `no_proxy`     | **never connects**; `/ide` → _"Failed to connect to Neovim"_; plugin shows `Connection timeout - clearing 1 queued @ mentions` |
| **Proxy + fix**     | same proxy **+** `no_proxy=localhost,127.0.0.1,::1` | **connects** again                                                                                                             |

The baseline connects even with several _other_ `~/.claude/ide/*.lock` files
present, so `CLAUDE_CODE_SSE_PORT` reliably disambiguates — the proxy is the only
thing that changes the outcome. This matches a `no_proxy` workaround reported in
the issue thread:

```sh
export no_proxy=localhost,127.0.0.1,::1   # their fix
```

Claude's WebSocket client honors the lowercase `http_proxy`/`all_proxy`
(`proxy-from-env` semantics) and, with no localhost exclusion, tunnels even
`ws://127.0.0.1:<port>` through the proxy — which cannot reach a loopback server.

### Secondary cause seen in the thread (multi-instance / discovery)

Most thread reports ("the 2nd instance fails", "the send is caught by the other
terminal", "only works when Claude is opened in another terminal") come from the
_discovery fallback_ used when `CLAUDE_CODE_SSE_PORT` does **not** reach Claude
(external-terminal provider, shell/tmux wrappers that reset env, older versions):

- With the env var **absent**, current Claude falls back to scanning
  `~/.claude/ide/*.lock` and **filters by workspace** (`/ide` literally prints
  _"Found N other running IDE(s). However, their workspace/project directories do
  not match the current cwd."_).
- With **exactly one** workspace-matching lock file it auto-connects; with **two**
  (two Neovim instances in the same project, or a stale lock file) it connects to
  **neither** — reproducing the timeout.
- Auto-connect via the env var (`CLAUDE_CODE_SSE_PORT`) or a _single_ unambiguous
  workspace match still happens automatically; but the ambiguous-discovery path
  surfaces a `/ide` tip — _"You can enable auto-connect to IDE in /config or with
  the --ide flag"_ — i.e. discovery-only auto-connect is heuristic/opt-in. A
  Claude-side change to that heuristic is a plausible (unverified) explanation for
  the "worked, then a Claude update broke it" / "lock file exists but no socket"
  reports (one such report cites CC 2.0.42), and is a question for the
  deep-research follow-up.

These discovery paths touch global `~/.claude/ide` state shared with other live
sessions, so they are documented here rather than automated. The deterministic,
side-effect-free repro below targets the proxy cause.

## Reproduce it

### Automated (proxy cause, real Claude)

```sh
# from repo root; needs nvim + a logged-in `claude` + agent-tty + jq
bash scripts/repro_issue_70.sh
```

Expected tail:

```
  [A_baseline] PASS  (... expected=connect, got=connect)
  [B_proxy]    PASS  (... expected=noconnect, got=noconnect)
  [C_no_proxy] PASS  (... expected=connect, got=connect)

PASS issue #70 reproduced: a proxy with no localhost exclusion blocks Claude's
     IDE WebSocket (B), while baseline (A) and the no_proxy fix (C) connect.
```

### Interactive (in the real plugin)

> **Note on branch state:** this fixture loads the plugin from the repo, so its
> behavior depends on whether the fix is present. On a branch/commit that
> **includes the fix**, the plugin injects `no_proxy` into the Claude terminal, so
> the steps below now **connect** (the `@` mention is delivered, no timeout) — that
> is the fix working. To watch the **original failure**, run the same steps against
> **pre-fix code** (check out the parent commit, or temporarily revert the
> `lua/claudecode/terminal.lua` change).

```sh
# proxy set, localhost NOT excluded
export http_proxy=http://127.0.0.1:1 https_proxy=http://127.0.0.1:1 all_proxy=http://127.0.0.1:1
unset no_proxy NO_PROXY

source fixtures/nvim-aliases.sh && vv issue-70      # or the explicit form below
#   NVIM_APPNAME=issue-70 XDG_CONFIG_HOME="$PWD/fixtures" nvim fixtures/issue-70/sample.txt
```

Then run `:Issue70Send` (or `<leader>s`). The plugin launches Claude and queues
`sample.txt`.

- **Pre-fix:** Claude cannot connect through the dead proxy; after ~10s the queue
  clears with `[ClaudeCode] [queue] [ERROR] Connection timeout - clearing 1 queued @ mentions`.
- **With the fix:** the plugin adds `localhost` to `no_proxy`, so Claude connects and
  the `@` mention is delivered — no timeout.

Unlike this interactive path, the automated `scripts/repro_issue_70.sh` is
**unaffected by the fix**: it launches Claude with its own environment, bypassing the
plugin's env injection, so it reproduces the root cause at the Claude level on any
checkout (and `export no_proxy=localhost,127.0.0.1,::1` is what makes it connect).

> Set `ISSUE70_LOG=/path/to/log` before launching to also tee the plugin's
> notifications (including the ERROR) to a file for scripted assertions.

## Workarounds (today, no code change)

- `export no_proxy=localhost,127.0.0.1,::1` (and `NO_PROXY=...`) in the
  environment Neovim is launched from.
- Avoid two Neovim instances sharing one project dir; clean stale
  `~/.claude/ide/*.lock` files.
- Ensure `CLAUDE_CODE_SSE_PORT` actually reaches Claude (avoid env-stripping
  terminal wrappers).

## Pointers for a fix (deep-research follow-up)

- The plugin could inject a localhost `NO_PROXY`/`no_proxy` into the env table it
  passes to the Claude terminal (`get_claude_command_and_env` in
  `lua/claudecode/terminal.lua`) so the loopback IDE socket is never proxied —
  with care not to clobber a user's existing `no_proxy`.
- The `Connection timeout` error is generic; surfacing _why_ (proxy set / no
  client handshake / multiple matching lock files) would make this class of
  report self-diagnosing.
