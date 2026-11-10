# Share the selection

While Claude is connected, Neovim tells it what the user is looking at. Every selection or cursor change is pushed as a `selection_changed` notification, and Claude can ask for the current or the latest selection with `getCurrentSelection` and `getLatestSelection`.

## Sub-features

- `sel-visual-notify` pushes `selection_changed` with the selected text and 0-based positions while the user selects in Visual or Select mode. A blockwise selection is sent as one span from its first to its last position, not as a rectangle. A charwise selection that reaches past the end of a line includes the newline.
- `sel-cursor-notify` pushes an empty selection (`isEmpty: true`) at the cursor after the user moves away from a selection, or edits the text it holds.
- `sel-current` answers `getCurrentSelection` with `success`, `text`, `filePath`, `fileUrl`, and `selection`.
- `sel-latest` answers `getLatestSelection` with the last selection Neovim pushed.
- `sel-untracked` with `track_selection = false` pushes nothing. `getCurrentSelection` then reads the editor when Claude asks: the Visual selection, or the cursor position. `getLatestSelection` answers `{"success":false,"message":"No selection available"}`.

## How to get to it (user POV)

- The user selects text in Visual mode (`v`, `V`, `<C-v>`) or Select mode (`gh`, `gH`), or moves the cursor in a file buffer.
- The user sets `track_selection = false` in `setup()`.
- Claude calls `getCurrentSelection` or `getLatestSelection`.

## Driving it with vcn.sh

Preconditions:

- Baseline launch with `hello.txt` open and `$V doctor` all `ok`.
- Record the notification baseline with `n0=$(wc -l < "$OUT/ws-in.jsonl")`.

Steps:

- **Select two lines.** Run `$V keys gg V j` and `$V until 'mode()' V`. Within one second, `tail -n +$((n0 + 1)) "$OUT/ws-in.jsonl" | jq -c 'select(.method == "selection_changed") | .params'` ends with `text` `alpha\nbeta`, `filePath` `<WORK>/hello.txt`, `start` `{line 0, character 0}`, `end` `{line 1, character 4}`, and `isEmpty` `false`. Run `$V capture sel-visual-notify` and `$V screenshot sel-visual-notify` now, while the lines are selected.
- **Ask for the current selection.** Run `$V tool s1 getCurrentSelection` and `$V await s1 | jq -r '.result.content[0].text'`. The JSON has `"success":true` and the same `text` and `selection`.
- **Move away.** Run `$V keys Escape`, `$V keys G`, and `$V until "line('.')" 3`. Within one second the newest `selection_changed` has `text` `""`, `start` and `end` at `{line 2, character 0}`, and `isEmpty` `true`.
- **Ask for the latest selection.** Run `$V tool s2 getLatestSelection` and `$V await s2 | jq -r '.result.content[0].text'`. It matches the newest `selection_changed` params.
- **Select mode.** Run `$V keys gH` and `$V until 'mode()' S`. The newest `selection_changed` has `text` `gamma`, from `{line 2, character 0}` to `{line 2, character 5}`. Leave with `$V keys Escape`.
- **Block and line end.** Run `$V keys gg0l Ctrl+V j` and `$V until 'char2nr(mode())' 22`. The newest `selection_changed` has `text` `lpha\nbe`, from `{line 0, character 1}` to `{line 1, character 2}`. Leave with `$V keys Escape` and `$V until 'mode()' n`. Run `$V keys gg0v '$'` and `$V until 'mode()' v`. The newest has `text` `alpha\n`, ending at `{line 1, character 0}`.
- **Tracking off.** On a fresh `VCN_SETUP='{"track_selection":false}' $V launch`, run `$V keys G V` and `$V until 'mode()' V`. After one second `$OUT/ws-in.jsonl` holds no `selection_changed`. `getCurrentSelection` answers `text` `gamma` from `{line 2, character 0}` to `{line 2, character 5}`, and `getLatestSelection` answers `No selection available`. After `$V keys Escape`, `$V until 'mode()' n`, and `$V keys gg l`, `getCurrentSelection` answers an empty selection at `{line 0, character 1}`.
- **Proof.** Keep the `sel-visual-notify` capture with the matching `selection_changed` lines from `$OUT/ws-in.jsonl` with them, and end with `$V record selection`.

## Gotchas

- Leaving visual mode keeps the last visual selection until the user moves the cursor, starts another selection, lets an operator consume it, edits its text, or goes to another file. A visit to the Claude terminal keeps it. `getCurrentSelection` still returns it with `isEmpty: false`. Move the cursor before you test the empty state.
- While tracking is on, `getCurrentSelection` and `getLatestSelection` both return the selection Neovim last pushed. `getCurrentSelection` only adds `"success":true`. Neither reads the editor again, so during the debounce both return the older selection. Three events do not wait for the debounce, and each pushes at once: leaving visual mode, editing the held text or consuming it with an operator, and moving the cursor away from a held selection. Entering another file (`:b`, a window switch) waits for the debounce: measured about 100 ms.
- Most notifications are debounced; the three events above are not. Wait for the mode or cursor state with `$V until`, then allow about one second before you read `ws-in.jsonl`.
- Lines and characters are 0-based in every payload. `:3` in Neovim is `line: 2`.
- Notifications reach only a connected client. If `$V doctor` fails the handshake line, nothing arrives.
