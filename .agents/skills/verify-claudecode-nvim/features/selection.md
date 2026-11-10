# Share the selection

While Claude is connected, Neovim tells it what the user is looking at. Every selection or cursor change is pushed as a `selection_changed` notification, and Claude can ask for the current or the latest selection with `getCurrentSelection` and `getLatestSelection`.

## Sub-features

- `sel-visual-notify` pushes `selection_changed` with the selected text and 0-based positions while the user selects in visual mode.
- `sel-cursor-notify` pushes an empty selection (`isEmpty: true`) at the cursor after the user moves away.
- `sel-current` answers `getCurrentSelection` with `success`, `text`, `filePath`, `fileUrl`, and `selection`.
- `sel-latest` answers `getLatestSelection` with the last selection Neovim pushed.

## How to get to it (user POV)

- The user selects text in visual mode (`v`, `V`, `<C-v>`) or moves the cursor in a file buffer.
- Claude calls `getCurrentSelection` or `getLatestSelection`.

## Driving it with vcn.sh

Preconditions:

- Baseline launch with `hello.txt` open and `$V doctor` all `ok`.
- Record the notification baseline with `n0=$(wc -l < "$OUT/ws-in.jsonl")`.

Steps:

- **Select two lines.** Run `$V keys gg V j` and `$V until 'mode()' V`. Within one second, `tail -n +$((n0 + 1)) "$OUT/ws-in.jsonl" | jq -c 'select(.method == "selection_changed") | .params'` ends with `text` `alpha\nbeta`, `filePath` `<WORK>/hello.txt`, `start` `{line 0, character 0}`, `end` `{line 1, character 4}`, and `isEmpty` `false`.
- **Ask for the current selection.** Run `$V tool s1 getCurrentSelection` and `$V await s1 | jq -r '.result.content[0].text'`. The JSON has `"success":true` and the same `text` and `selection`.
- **Move away.** Run `$V keys Escape`, `$V keys G`, and `$V until "line('.')" 3`. Within one second the newest `selection_changed` has `text` `""`, `start` and `end` at `{line 2, character 0}`, and `isEmpty` `true`.
- **Ask for the latest selection.** Run `$V tool s2 getLatestSelection` and `$V await s2 | jq -r '.result.content[0].text'`. It matches the newest `selection_changed` params.
- **Proof.** Run `$V capture sel-visual-notify` and `$V screenshot sel-visual-notify` while the lines are selected. Keep the matching `selection_changed` lines from `$OUT/ws-in.jsonl` with them, and end with `$V record selection`.

## Gotchas

- Leaving visual mode without moving the cursor keeps the last visual selection. `getCurrentSelection` still returns it with `isEmpty: false`. Move the cursor before you test the empty state.
- Notifications are debounced. Wait for the mode or cursor state with `$V until`, then allow about one second before you read `ws-in.jsonl`.
- Lines and characters are 0-based in every payload. `:3` in Neovim is `line: 2`.
- Notifications reach only a connected client. If `$V doctor` fails the handshake line, nothing arrives.
