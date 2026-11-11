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
- A real nvim binary and a real node binary, not a version-manager shim: the script starts both with an empty environment, and a shim does not start that way. In a checkout that mise does not trust, `mise which nvim` fails and `PATH` can hold a shim. Then set `VCN_NVIM=<real nvim binary>`, for example `~/.local/share/mise/installs/neovim/0.12.3/bin/nvim`. The script exits 2 and names the binary that does not start. When the server does not come up for another reason, it prints the last lines of nvim's output.
- No `claude` program on `PATH=/usr/bin:/bin`. The script exits 2 when it finds one.

Steps:

- **Whole proof.** Run `.agents/skills/verify-claudecode-nvim/scripts/proof-tools-call-wire.sh [tree]`. `tree` is a plugin tree with `lua/claudecode`, and defaults to this checkout. It prints one `ok: <case>` or `FAIL: <case>: <reason>` line per case and ends with `COUNT tools-call-wire cases=<n> failed=<n> leaks=<n>`. A pass is `failed=0 leaks=0` with at least one case, and exit 0. A failure exits 1, and its `FAIL` lines say what the case wanted and what came back. Exit 2 means the probe could not run, or that it judged fewer cases than the table holds (an empty table too). It prints no `COUNT` line then. A server that goes away during the run ends the probe at once with exit 2.
- **Red proof.** Run the probe against main from before #500: `dir=$(mktemp -d); git archive f932d7b6a91c71c3728257ae6284bf03f9d09c77 | tar -x -C "$dir"; .agents/skills/verify-claudecode-nvim/scripts/proof-tools-call-wire.sh "$dir"; echo "exit $?"; rm -rf "$dir"`. It prints `FAIL` lines, ends with `COUNT tools-call-wire cases=44 failed=30 leaks=15`, and `exit 1`.
- **Neovim 0.8.** Run the whole proof with `VCN_NVIM=<nvim of the v0.8.0 release>`. It prints the same lines as on 0.12.3.
- **Normalization and the leak rule.** `proof-tools-call-wire.mjs` reads every key and every string of every frame that the server sends, one by one, at every depth, as the frame came off the wire. It decodes a string that holds JSON (a text item) first. The path rewrite then applies to each key and string on its own: the folder nvim runs in becomes `$CWD`, the tree becomes `$TREE` and the real home folder becomes `$HOME`, in that order. The real home folder comes from the password database, because the checker starts with an empty environment. A frame leaks when a key or a string then holds `.lua:` and a digit, `$TREE` or `$HOME`, or holds 8 or more characters of the auth token in a row. This covers every field of the answer, each key, and each frame that comes before or after the answer. A normal answer is compared with the answer written in the case table. The comparison reads a copy of the frame that rewrites the strings but not the keys, so two keys that the rewrite would make equal never pass as a correct answer.

## Gotchas

- The table holds `params`, `name`, `getWorkspaceFolders` and `openFile`. Another tool is not checked.
- The folder nvim runs in is not a leak, because `getWorkspaceFolders` returns it on purpose. The rewrite handles it first, so the answer passes even when that folder lies under the real home folder.
- nvim starts with an empty environment apart from `PATH=/usr/bin:/bin`, `WIRE_PARENT`, `WIRE_TREE`, `WIRE_CWD`, and `HOME`, `TMPDIR`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` and `CLAUDE_CONFIG_DIR` in the temp dir. It runs with `terminal.provider = "none"`. The checker starts with no variable, so no variable of the caller, such as `NODE_OPTIONS`, loads code into the process that holds the token. The run leaves nothing outside the temp dir, not even nvim's own temp root. The script stops nvim and the client by PID and removes its temp dir `/tmp/wire-probe.XXXXXX` on every end that bash can trap (a normal exit, a failed case, TERM, INT and HUP).
- The auth token lives in the memory of nvim and of the checker, and in the `0600` lock file in that temp dir. The checker sends it only in the upgrade header. Text from a frame or from the lock file reaches the output only when it holds no run of 8 or more characters of the token, otherwise the output says `<holds the auth token>`. The checker prints no message of a JSON parser: a frame that is not JSON and a lock file that does not parse each end the run with exit 2 and a fixed message. nvim's output file holds no token. The script prints its last lines only while no lock file exists, and the plugin logs only the length of its token.
- After SIGKILL of the script no cleanup runs. nvim checks its parent every half second and quits when the script is gone. Its server stop removes the lock file and closes the socket, which ends the checker. Both processes are gone and the lock file is gone within 5 seconds. The temp dir stays then, without a token.
- A case with no answer in 3 seconds fails with `no answer in 3 s`.
