# claudecode.nvim verification map

This directory is the maintained source for verifying the user-facing behavior of claudecode.nvim. Read this index before driving the plugin, then use the matching feature file as the recipe.

## Baseline preconditions

- Launch a fresh run with `.agents/skills/verify-claudecode-nvim/scripts/vcn.sh launch`. It opens `hello.txt` with the default config plus `terminal.provider = "none"`.
- Start every bash call with `export VCN_STATE=<value launch printed>; source "$VCN_STATE/run.env"; V=.agents/skills/verify-claudecode-nvim/scripts/vcn.sh`.
- `$WORK/hello.txt` is `alpha`, `beta`, `gamma` and `$WORK/other.txt` is `one`, `two`, `three`, `four`.
- `$V doctor` reports nine `ok` lines, including `a client finished the WebSocket handshake`.
- Never drive an nvim, agent-tty session, or lock file that this run did not start.

## Driving conventions

- Start every recipe from the baseline state unless its preconditions say otherwise. A recipe that changed the seed files needs a fresh launch.
- The user acts through `$V keys`. Claude acts through `$V tool`. `$V expr` and `$V until` only observe.
- `$V keys` presses an argument that is an agent-tty key name (`Enter`, `Escape`, `Ctrl+W`) and types any other argument as text. `$V keys ':w' Enter` types `:w` and presses Enter.
- Wait for a state with `$V until`, never a fixed sleep. Notifications are the one exception: they carry no id, so read `$OUT/ws-in.jsonl` after the action.
- Build tool arguments with `jq -nc --arg ...` so paths and newlines stay valid JSON.
- Give each openDiff call a unique id and a unique `tab_name` that contains `✻` and `⧉`, the shape Claude sends.
- Treat every command as literal. Keep quoted names, ids, and flags unchanged.

## Proof and skip reporting

- Capture the screen before and after each user action with `$V capture <feature-id>-<step>` (text) and `$V screenshot <feature-id>-<step>` (PNG).
- End each recipe with `$V record <feature file name>`, for example `$V record open-file`. It saves a WebM of the session so far.
- Keep the response JSON with the captures: `$V await <id> > "$OUT/<feature-id>-response.json"`.
- Check file side effects with `sha256sum "$WORK/<file>"` before and after the action.
- Record the feature ID and entry point (key, `:Command`, or tool) with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with vcn.sh` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [Review a proposed diff](./open-diff.md) covers openDiff blocking, accept through `:w` and `:ClaudeCodeDiffAccept`, reject through `:q` and `:ClaudeCodeDiffDeny`, and `close_tab` finalization.
- [Close diffs in bulk](./close-diffs.md) covers the `closeAllDiffTabs` tool and the `:ClaudeCodeCloseAllDiffs` command.
- [Open a file for the user](./open-file.md) covers openFile with text and line selections and the background (`makeFrontmost: false`) form.
- [Share the selection](./selection.md) covers `selection_changed` notifications, `getCurrentSelection`, and `getLatestSelection`.
- [Send context with an at-mention](./send-at-mention.md) covers `:ClaudeCodeSend` from visual mode and `:ClaudeCodeAdd` with and without a line range.
