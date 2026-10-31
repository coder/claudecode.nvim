# Send context with an at-mention

The user hands Claude a file or a line range as context. `:ClaudeCodeSend` in visual mode and `:ClaudeCodeAdd <file> [start end]` push an `at_mentioned` notification with a cwd-relative path and 0-based lines.

## Sub-features

- `send-visual` pushes the visually selected line range of the current file on `:ClaudeCodeSend`.
- `send-add-range` pushes a file and line range on `:ClaudeCodeAdd <file> <start> <end>`, converting the 1-based arguments to 0-based lines.
- `send-add-file` pushes a whole file, with no line fields, on `:ClaudeCodeAdd <file>`.

## How to get to it (user POV)

- Select lines in visual mode, then type `:ClaudeCodeSend` (Neovim prefills `'<,'>`).
- Run `:ClaudeCodeAdd <file>` or `:ClaudeCodeAdd <file> <start> <end>` in normal mode.

## Driving it with vcn.sh

Preconditions:

- Baseline launch with `hello.txt` open and `$V doctor` all `ok`.
- Record the notification baseline with `n0=$(wc -l < "$OUT/ws-in.jsonl")`.

Steps:

- **Send a visual selection.** Run `$V keys gg V j`, `$V until 'mode()' V`, then `$V keys ':ClaudeCodeSend' Enter`. Within one second `tail -n +$((n0 + 1)) "$OUT/ws-in.jsonl" | jq -c 'select(.method == "at_mentioned") | .params'` prints `{"filePath":"hello.txt","lineStart":0,"lineEnd":1}`. `$V expr 'mode()'` prints `n`.
- **Add a file range.** Run `$V keys ':ClaudeCodeAdd other.txt 2 3' Enter`. The next `at_mentioned` params are `{"filePath":"other.txt","lineStart":1,"lineEnd":2}`.
- **Add a whole file.** Run `$V keys ':ClaudeCodeAdd other.txt' Enter`. The next `at_mentioned` params are `{"filePath":"other.txt"}`.
- **Proof.** Type the command with `$V keys ':ClaudeCodeSend'`, then run `$V capture send-visual` and `$V screenshot send-visual` with the selection and the typed command visible, before `$V keys Enter`. Keep the `at_mentioned` lines from `$OUT/ws-in.jsonl`, and end with `$V record send-at-mention`.

## Gotchas

- Without a connected client the plugin queues the mention and tries to open its Claude terminal. The `none` provider opens nothing, so the mention never arrives. Check the handshake line of `$V doctor` first.
- Paths are relative to Neovim's cwd (`$WORK`). A file outside it arrives as an absolute path (`:ClaudeCodeAdd /etc/hostname` gave `{"filePath":"/etc/hostname"}`).
- JSON key order varies between runs. Compare with `jq`, not with string equality.
