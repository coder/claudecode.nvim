# Check every tool call at the entry

The server checks the `params` of each `tools/call` request once, where the request enters, before a tool runs (#500). A malformed call gets JSON-RPC error `-32602` that names the wrong parameter. A valid call gets its normal answer. No frame that the server sends shows a Lua source path, the plugin's folder or the user's home folder. The probe sends the cases to the plugin server of one tree over a real WebSocket and judges each answer against one table.

## Sub-features

- `call-params` answers `-32602` naming `params` when `params` is absent, `false`, `null`, `true`, a number, a string, `[]` or `[1]`. It names `name` for `{}`.
- `call-name` answers `-32602` naming `name` when `name` is `null`, `true`, `false`, a number, a list or an object.
- `call-arguments` answers `-32602` naming `arguments` when `arguments` is present and is not an object. A call with `arguments` absent or `{}` is a call without parameters.
- `call-string-param` answers `-32602` naming `filePath` when the `filePath` of `openFile` is not a string. `""` is a string, so `openFile` answers `-32000` `File not found: `.
- `call-normal` answers a valid `getWorkspaceFolders` call with the workspace folder: `name` `work`, `path`, `uri` and `rootPath` of the folder that nvim runs in.
- `call-no-leak` keeps every frame that the server sends free of a Lua position (`.lua:` and a digit), the plugin tree path and a path under the real home folder.

## How to get to it (user POV)

- The Claude CLI sends `tools/call` over the WebSocket. The user sees the tool error in Claude's reply, never a Lua path.

## Driving it with vcn.sh

Preconditions:

- Neovim 0.8 or newer and Node 22 or newer, which has a global `WebSocket` (the probe ran on Node 22.23.4 and 26.12.1). The script takes nvim from `VCN_NVIM`, else `mise which nvim`, else `PATH`, and node from `mise which node`, else `PATH`. It needs no `$V launch`, agent-tty or Chromium.
- No `claude` program on `PATH=/usr/bin:/bin`. The script exits 2 when it finds one.

Steps:

- **Whole proof.** Run `.agents/skills/verify-claudecode-nvim/scripts/proof-tools-call-wire.sh [tree]`. `tree` is a plugin tree with `lua/claudecode`, and defaults to this checkout. It prints one `ok: <case>` or `FAIL: <case>: <reason>` line per case and ends with `COUNT tools-call-wire cases=<n> failed=<n> leaks=<n>`. A pass is `failed=0 leaks=0` with at least one case, and exit 0. A failure exits 1, and its `FAIL` lines say what the case wanted and what came back. Exit 2 means the probe could not run, or that it judged fewer cases than the table holds (an empty table too). It prints no `COUNT` line then. A server that goes away during the run ends the probe at once with exit 2.
- **Red proof.** Run the probe against main from before #500: `dir=$(mktemp -d); git archive f932d7b6a91c71c3728257ae6284bf03f9d09c77 | tar -x -C "$dir"; .agents/skills/verify-claudecode-nvim/scripts/proof-tools-call-wire.sh "$dir"; echo "exit $?"; rm -rf "$dir"`. It prints `FAIL` lines, ends with `COUNT tools-call-wire cases=44 failed=30 leaks=15`, and `exit 1`.
- **Neovim 0.8.** Run the whole proof with `VCN_NVIM=<nvim of the v0.8.0 release>`. It prints the same lines as on 0.12.3.
- **Normalization.** Before a case is judged, `proof-tools-call-wire.mjs` rewrites every string of every frame that the server sends, after it decodes a text item that holds JSON: the folder nvim runs in becomes `$CWD`, the tree becomes `$TREE` and the real home folder becomes `$HOME`, in that order. A normal answer is compared with the answer written in the case table after this rewrite. A frame leaks when it still holds `.lua:` and a digit, `$TREE`, `$HOME` or the auth token. This covers every field of the answer and each frame that comes before or after it. A `FAIL` line prints a leaking frame, except one that holds the auth token.

## Gotchas

- The table holds `params`, `name`, `getWorkspaceFolders` and `openFile`. Another tool is not checked.
- The folder nvim runs in is not a leak, because `getWorkspaceFolders` returns it on purpose. The rewrite handles it first, so the answer passes even when that folder lies under the real home folder (`HOME=/tmp .../proof-tools-call-wire.sh` runs that case).
- nvim runs with an empty environment apart from `PATH=/usr/bin:/bin`, a scratch `HOME` and `XDG_*_HOME`, `CLAUDE_CONFIG_DIR`, and `terminal.provider = "none"`. The script stops nvim and the client by PID and removes its temp dir `/tmp/wire-probe.XXXXXX` on every end that bash can trap (a normal exit, a failed case, TERM, INT and HUP).
- The auth token lives in the memory of nvim and of the checker, and in the `0600` lock file in that temp dir. The checker sends it only in the upgrade header. The script prints no token, and nvim's output file holds none.
- After SIGKILL of the script no cleanup runs. nvim checks its parent every half second and quits when the script is gone. Its server stop removes the lock file and closes the socket, which ends the checker. Both processes are gone and the lock file is gone within 5 seconds. The temp dir stays then, without a token.
- A case with no answer in 3 seconds fails with `no answer in 3 s`.
