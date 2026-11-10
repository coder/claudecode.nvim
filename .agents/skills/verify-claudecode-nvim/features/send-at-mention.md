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
- **Send with a real terminal.** Launch with `VCN_SETUP='{"terminal_cmd":"sh","terminal":{"provider":"native"}}' $V launch -c 'xnoremap S <cmd>ClaudeCodeSend<CR>' hello.txt`. For snacks, set `"provider":"snacks"` and add `--cmd 'set rtp^=<snacks.nvim dir>'` to the launch arguments. Run `$V keys ':ClaudeCode' Enter` and `$V until '&buftype' terminal`, then hide it with `$V keys 'Ctrl+\' 'Ctrl+N'`, `$V until 'mode()' n`, and `$V keys ':ClaudeCode' Enter`. Send with `$V keys gg V j`, `$V until 'mode()' V`, and `$V keys S`. `$V expr "mode() . '|' . bufname()"` must print `n|hello.txt`, and a typed `$V keys x` must delete a character. Repeat with `:ClaudeCodeSend` typed instead of `S`. Native, and snacks with either `S` or the typed command, print `n|hello.txt`. Before the fix for #423, snacks with the `S` mapping printed `i|hello.txt`, and `x` typed into the buffer.
- **Send with no terminal yet, or after the float was closed.** Both reach the show path of the previous step. For no terminal, run its launch command with `"provider":"snacks"`, skip `:ClaudeCode`, and send with `$V keys gg V j`, `$V until 'mode()' V`, `$V keys S`. For the float, add `"snacks_win_opts":{"position":"float","width":0.5,"height":0.5}` inside `terminal` of `VCN_SETUP`, run `:ClaudeCode`, `Ctrl+\` `Ctrl+N`, then `:close` (not a second `:ClaudeCode`), `$V until 'bufname()' hello.txt`, and send the same way. `$V expr "mode() . '|' . bufname()"` must print `n|hello.txt`. Then `$V keys Ctrl+W l` must enter the terminal in terminal mode (`$V expr mode()` prints `t`), also for the terminal that the no-terminal send created. Before the fix for #423 the no-terminal send printed `n|term://...` and the float send printed `t|term://...`, and `Ctrl+W l` into the terminal that the send created printed `n`.
- **Proof.** Type the command with `$V keys ':ClaudeCodeSend'`, then run `$V capture send-visual` and `$V screenshot send-visual` with the selection and the typed command visible, before `$V keys Enter`. Keep the `at_mentioned` lines from `$OUT/ws-in.jsonl`, and end with `$V record send-at-mention`.

## Gotchas

- The `none` provider opens no terminal. Without a connected client the plugin queues the mention and tries to open its Claude terminal, so the mention never arrives. Check the handshake line of `$V doctor` first. With a client, a send shows the hidden Claude terminal without focus, and `none` skips that too, so a mode or focus change from showing it (#423) appears only in **Send with a real terminal**.
- Paths are relative to Neovim's cwd (`$WORK`). A file outside it arrives as an absolute path (`:ClaudeCodeAdd /etc/hostname` gave `{"filePath":"/etc/hostname"}`).
- JSON key order varies between runs. Compare with `jq`, not with string equality.
