# Send context with an at-mention

The user hands Claude a file, a directory, or a line range as context. `:ClaudeCodeSend` in Visual or Select mode, `:ClaudeCodeAdd <path> [start [end]]`, and `:ClaudeCodeTreeAdd` in a file explorer push an `at_mentioned` notification with a cwd-relative path and 0-based lines.

## Sub-features

- `send-visual` pushes the visually selected line range of the current file on `:ClaudeCodeSend`.
- `send-add-range` pushes a file and line range on `:ClaudeCodeAdd <file> <start> <end>`, converting the 1-based arguments to 0-based lines.
- `send-add-file` pushes a whole file, with no line fields, on `:ClaudeCodeAdd <file>`. `%` names the current file, `\ ` escapes a space, and a start line alone sends only `lineStart`.
- `send-add-dir` pushes a directory as a path that ends in `/` and drops any line numbers.
- `send-add-errors` sends nothing and shows an error for a missing path or a start line after the end line.
- `send-mapped` sends from a Visual or Select mode mapping to `<cmd>ClaudeCodeSend<CR>`, as in the README, and leaves the user in Normal mode.
- `send-tree` sends the file under the cursor in netrw on `:ClaudeCodeTreeAdd` or `:ClaudeCodeSend`.
- `send-queue` holds a mention made while no client is connected and sends it to the next client that connects within `queue_timeout` (default 5000 ms).

## How to get to it (user POV)

- Select lines in visual mode, then type `:ClaudeCodeSend` (Neovim prefills `'<,'>`).
- Run `:ClaudeCodeAdd <path>`, `:ClaudeCodeAdd <path> <start>`, or `:ClaudeCodeAdd <path> <start> <end>` in normal mode.
- Press a mapping to `<cmd>ClaudeCodeSend<CR>` in Visual or Select mode.
- Run `:ClaudeCodeTreeAdd` or `:ClaudeCodeSend` in a file explorer buffer such as netrw.

## Driving it with vcn.sh

Preconditions:

- Baseline launch with `hello.txt` open and `$V doctor` all `ok`.
- Record the notification baseline with `n0=$(wc -l < "$OUT/ws-in.jsonl")`.

Steps:

- **Send a visual selection.** Run `$V keys gg V j`, `$V until 'mode()' V`, then `$V keys ':ClaudeCodeSend' Enter`. Within one second `tail -n +$((n0 + 1)) "$OUT/ws-in.jsonl" | jq -c 'select(.method == "at_mentioned") | .params'` prints `{"filePath":"hello.txt","lineStart":0,"lineEnd":1}`. `$V expr 'mode()'` prints `n`.
- **Add a file range.** Run `$V keys ':ClaudeCodeAdd other.txt 2 3' Enter`. The next `at_mentioned` params are `{"filePath":"other.txt","lineStart":1,"lineEnd":2}`.
- **Add a whole file.** Run `$V keys ':ClaudeCodeAdd other.txt' Enter`. The next `at_mentioned` params are `{"filePath":"other.txt"}`.
- **More `:ClaudeCodeAdd` forms.** Each line runs `$V keys ':ClaudeCodeAdd <args>' Enter`, then reads the next `at_mentioned` params:
  - `other.txt 2` gives `{"filePath":"other.txt","lineStart":1}`.
  - `%` gives `{"filePath":"hello.txt"}`.
  - `./other.txt` gives `{"filePath":"./other.txt"}`.
  - `. 1 2` gives `{"filePath":"./"}`.
  - After `$V keys ':w my\ notes.txt' Enter`, `my\ notes.txt 1 2` gives `{"filePath":"my notes.txt","lineStart":0,"lineEnd":1}`.
  - `missing.txt` and `other.txt 3 2` send nothing. `:messages` ends with `ClaudeCodeAdd: File or directory does not exist: missing.txt` and `ClaudeCodeAdd: Start line (3) must be <= end line (2)`.
- **Send from a mapping.** Map `S` as the README does: `$V keys ':vnoremap S <cmd>ClaudeCodeSend<CR>' Enter`. Run `$V keys G V`, `$V until 'mode()' V`, and `$V keys S`: the params are `{"filePath":"hello.txt","lineStart":2,"lineEnd":2}` and `$V expr 'mode()'` prints `n`. Select mode works the same: `$V keys gg gH`, `$V until 'mode()' S`, `$V keys S` sends line 0.
- **Send from netrw.** Run `$V keys ':Explore' Enter`, `$V until '&filetype' netrw`, and `$V keys '/^other\.txt' Enter`. `$V keys ':ClaudeCodeTreeAdd' Enter` and then `$V keys ':ClaudeCodeSend' Enter` each send `{"filePath":"other.txt"}`. Return with `$V keys ':b hello.txt' Enter`.
- **Queue while disconnected.** Run `$V disconnect`, then `$V until 'luaeval("require(\"claudecode\").is_claude_connected() and 1 or 0")' 0`. Send `gg V j` with `:ClaudeCodeSend`. Run `VCN_CLIENT=b $V connect` within five seconds. Within three seconds `$OUT/ws-in-b.jsonl` holds one `at_mentioned` with `{"filePath":"<WORK>/hello.txt","lineStart":0,"lineEnd":1}`. A queued mention keeps the absolute path.
- **Send with a real terminal.** Launch with `VCN_SETUP='{"terminal_cmd":"sh","terminal":{"provider":"native"}}' $V launch -c 'xnoremap S <cmd>ClaudeCodeSend<CR>' hello.txt`. For snacks, check out the commit the repo's fixtures pin, and check it before you load it: `P=$(jq -r '."snacks.nvim".commit' fixtures/snacks-picker/lazy-lock.json) && git clone -q --no-checkout https://github.com/folke/snacks.nvim <dir> && git -C <dir> checkout -q --detach "$P" && [ "$(git -C <dir> rev-parse HEAD)" = "$P" ]`. Never load an unpinned branch: setup runs its Lua as you. Then set `"provider":"snacks"` and add `--cmd 'set rtp^=<dir>'` to the launch arguments. The repo has no snacks checkout, so without network this path is unreachable. Run `$V keys ':ClaudeCode' Enter` and `$V until '&buftype' terminal`, then hide it with `$V keys 'Ctrl+\' 'Ctrl+N'`, `$V until 'mode()' n`, and `$V keys ':ClaudeCode' Enter`. Send with `$V keys gg V j`, `$V until 'mode()' V`, and `$V keys S`. `$V expr "mode() . '|' . bufname()"` must print `n|hello.txt`, and a typed `$V keys x` must delete a character. Show the terminal again with `$V keys ':ClaudeCodeFocus' Enter` and `$V until 'mode()' t`, hide it as before, and repeat with `:ClaudeCodeSend` typed instead of `S`. A send to a terminal that is already visible does not test showing it. On main, snacks with the `S` mapping prints `i|hello.txt`, and `x` types into the buffer (#423). Native, and snacks with the typed command, print `n|hello.txt`.
- **Proof.** Type the command with `$V keys ':ClaudeCodeSend'`, then run `$V capture send-visual` and `$V screenshot send-visual` with the selection and the typed command visible, before `$V keys Enter`. Keep the `at_mentioned` lines from `$OUT/ws-in.jsonl`, and end with `$V record send-at-mention`.

## Gotchas

- The `none` provider opens no terminal. Without a connected client the plugin queues the mention and tries to open its Claude terminal. The mention reaches only a client that connects within `queue_timeout`, so check the handshake line of `$V doctor` first. With a client, a send shows the hidden Claude terminal without focus (with focus when `focus_after_send = true`), and `none` skips that too, so a mode or focus change from showing it (#423) appears only in **Send with a real terminal**.
- Paths are relative to Neovim's cwd (`$WORK`). A file outside it arrives as an absolute path (`:ClaudeCodeAdd /etc/hostname` gave `{"filePath":"/etc/hostname"}`). A path typed as `./other.txt` arrives unchanged, and a queued visual send arrives absolute.
- JSON key order varies between runs. Compare with `jq`, not with string equality.
