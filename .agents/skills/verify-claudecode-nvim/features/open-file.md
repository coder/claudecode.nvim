# Open a file for the user

Claude opens a file in the user's editor with the `openFile` tool, optionally selecting a text span or a line range so the user sees exactly what Claude means. With `makeFrontmost: false` Claude gets file details back as JSON.

## Sub-features

- `file-open` opens `filePath` in the main editor window and answers `Opened file: <path>`.
- `file-select-text` selects from the first `startText` match through the `endText` match in visual mode.
- `file-select-lines` selects lines `startLine` through `endLine` (1-based) in visual mode.
- `file-background` with `makeFrontmost: false` answers JSON with `success`, `filePath`, `languageId`, and `lineCount`.
- `file-missing` answers a JSON-RPC error for a path that does not exist.

## How to get to it (user POV)

- Claude calls `openFile` while the user works in Neovim.

## Driving it with vcn.sh

Preconditions:

- Baseline launch with `hello.txt` open and `$V doctor` all `ok`.

Steps:

- **Open a file.** Run `$V tool o0 openFile "$(jq -nc --arg p "$WORK/other.txt" '{filePath:$p}')"` and `$V await o0`. The answer text is `Opened file: <WORK>/other.txt`, and `$V expr 'bufname()'` ends with `other.txt`.
- **Select a text span.** Run `$V tool o1 openFile "$(jq -nc --arg p "$WORK/other.txt" '{filePath:$p,startText:"two",endText:"three"}')"` and `$V await o1`. The answer text is `Opened file and selected text from "two" to "three"`. `$V expr "mode() . '|' . join(getregion(getpos('v'), getpos('.')), '/')"` must print `v|two/three`. Leave visual mode with `$V keys Escape`.
- **Select a line range.** Run `$V tool o2 openFile "$(jq -nc --arg p "$WORK/other.txt" '{filePath:$p,startLine:3,endLine:4}')"` and `$V await o2`. The answer text is `Opened file and selected lines 3 to 4`. The same `getregion` expression must print `v|three/four`. Leave with `$V keys Escape`.
- **Open in the background.** Run `$V tool o3 openFile "$(jq -nc --arg p "$WORK/hello.txt" '{filePath:$p,makeFrontmost:false}')"` and `$V await o3 | jq -r '.result.content[0].text'`. It prints JSON with `"success":true`, the absolute `filePath`, `"languageId":"text"`, and `"lineCount":3`.
- **Missing file.** Run `$V tool o4 openFile '{"filePath":"/nonexistent/x.txt"}'` and `$V await o4`. The response has an `error` object whose `data` is `File not found: /nonexistent/x.txt`.
- **Proof.** Run `$V capture file-select-text` and `$V screenshot file-select-text` while the span is selected. The status line shows `-- VISUAL --`. Keep the `getregion` output next to it, and end with `$V record open-file`.

## Gotchas

- A selection that starts one line early is a regression: the text span selects `one/two/three` and the line range selects `two/t`. Report it, and do not loosen the expected region to match it.
- The selection is a live visual mode. Send `Escape` before the next step, or the next keys extend the selection.
- With one window, `makeFrontmost: false` still swaps the visible buffer, because the main window is the current one. Focus behavior with several windows is not mapped yet.
