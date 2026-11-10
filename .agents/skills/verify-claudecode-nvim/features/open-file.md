# Open a file for the user

Claude opens a file in the user's editor with the `openFile` tool, optionally selecting a text span or a line range so the user sees exactly what Claude means. With `makeFrontmost: false` Claude gets file details back as JSON.

## Sub-features

- `file-open` opens `filePath` in the main editor window and answers `Opened file: <path>`.
- `file-select-text` selects from the first `startText` match through the `endText` match in visual mode.
- `file-select-lines` selects lines `startLine` through `endLine` (1-based) in visual mode.
- `file-background` with `makeFrontmost: false` answers JSON with `success`, `filePath`, `languageId`, and `lineCount`.
- `file-text-variants` `startText` alone selects that text, `selectToEndOfLine` extends the span to the end of its last line, an `endText` that is not found leaves the cursor at `startText` with no selection, and a `startText` that is not found opens the file without a selection. Each says so in the answer.
- `file-line-errors` answers error `-32602` for a `startLine` past the end of the file, and clamps an `endLine` past the end.
- `file-missing` answers a JSON-RPC error for a path that does not exist.
- `file-target-window` opens the file in the first suitable editor window. `makeFrontmost: true` (the default) moves focus there, and `false` leaves focus where it was.
- `file-preview` with `preview: true` opens the file and its selection in the preview window.
- `file-mid-command` in Insert mode, operator-pending mode, or the command line shows the file in the preview window without a selection, and leaves the user's window and mode alone.
- `file-reload` reloads a buffer whose file changed on disk, keeps a buffer that has unsaved changes, and raises no Neovim prompt (W11, W12, W13).

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
- **Missing file.** Run `$V tool o4 openFile '{"filePath":"/nonexistent/x.txt"}'` and `$V await o4`. The response has an `error` object with code `-32000` and `data` `File not found: /nonexistent/x.txt`.
- **Text and line variants.** Each call below uses `other.txt`. Leave Visual mode with `$V keys Escape` after each one that selects.
  - `{startText:"on",endText:"tw",selectToEndOfLine:true}` selects `v|one/two`.
  - `{startText:"hre"}` answers `Opened file and selected text "hre"` and selects `v|hre`.
  - `{startText:"two",endText:"zzz"}` answers `Opened file and positioned at "two" (end text "zzz" not found)`, and `$V expr "mode().line('.').col('.')"` prints `n21`.
  - `{startText:"zzz"}` answers `Opened file, but text "zzz" not found`.
  - `{startLine:3,endLine:99}` answers `Opened file and selected lines 3 to 4`.
  - `{startLine:5}` answers error `-32602` with `data` `startLine 5 is past the end of the file (4 lines)`.
- **Several windows.** Run `$V keys ':e hello.txt' Enter ':vsplit' Enter Ctrl+W l` and `$V until 'winnr()' 2`. openFile `other.txt` with `makeFrontmost:false`: `$V expr "winnr().'|'.fnamemodify(bufname(winbufnr(1)),':t').'|'.fnamemodify(bufname(),':t')"` prints `2|other.txt|hello.txt`. openFile `other.txt` again without it: `$V until 'winnr()' 1` passes. Then `$V keys ':only' Enter`.
- **Preview window.** openFile `hello.txt` with `{preview:true,startLine:2}`. `$V expr "&pvw.winnr('\$')"` prints `12`, and the `getregion` expression prints `v|beta`. Leave with `$V keys Escape` and `$V keys ':pclose' Enter`.
- **Mid-command.** Run `$V keys i` and `$V until 'mode()' i`, then openFile `hello.txt` with `{startLine:2}`. The answer is `Opened file and positioned at line 2 (shown in the preview window without a selection, because the user is in the middle of a command)`, and `$V expr "mode().&pvw.winnr('\$')"` prints `i02`. Leave with `$V keys Escape` and `$V keys ':pclose' Enter`.
- **Changed on disk.** Run this last, because it changes `other.txt`. Run `$V keys ':e other.txt' Enter`, then `printf 'one\ntwo\nthree\nfour\nfive\n' > "$WORK/other.txt"`. openFile `other.txt` with `{startLine:5}` selects `v|five`, and `$V doctor` stays all `ok`. Run `$V keys Escape`, `$V until 'mode()' n`, `$V keys gg0x ':e hello.txt' Enter`, and `printf 'six\n' >> "$WORK/other.txt"`, then openFile `other.txt`. `$V expr "getline(1).'|'.&modified.'|'.line('\$')"` prints `ne|1|5`: the unsaved change stays, and `$V doctor` stays all `ok`.
- **User configs.** For every change to the write or reload path, repeat the change's steps under each of these launches, on main and on head, and compare the buffer text, `&modified`, and `sha256sum` of the file: `$V launch -c 'autocmd BufLeave * update' hello.txt`, `$V launch -c 'autocmd BufEnter * if !&modified | edit | endif' hello.txt`, and `$V launch -c 'set cpo+=+' hello.txt`. For main, run `git archive origin/main | tar -x -C <dir>`, then `<dir>/.agents/skills/verify-claudecode-nvim/scripts/vcn.sh` from this checkout.
- **Proof.** Run `$V capture file-select-text` and `$V screenshot file-select-text` in the **Select a text span** step, before its `Escape`. The last screen row shows `-- VISUAL --`. Keep the `getregion` output next to it, and end with `$V record open-file`.

## Gotchas

- A selection that starts one line early is a regression: the text span selects `one/two/three` and the line range selects `two/t`. Report it, and do not loosen the expected region to match it.
- The selection is a live visual mode. Send `Escape` before the next step, or the next keys extend the selection.
- With one window, `makeFrontmost: false` still swaps the visible buffer, because the main window is the current one. Use **Several windows** to see that focus stays.
- A buffer with 'buftype' `acwrite` keeps 'modified', and `:checktime` skips it, with no FileChangedShell and no reload. With `nowrite` or `nofile`, 'modified' reads false.
- W13 (the file appeared after its buffer was opened) runs no FileChangedShell, so no autocommand can answer it.
- 'eventignorewin' (Neovim 0.11+) with FileChangedShell skips the event for the current window's buffer, and for another buffer only when every window that shows it sets it. Neovim then asks W12 itself for unsaved changes, or W11 under 'noautoread'.
- With `cpo+=+`, `:w {file}` resets 'modified', though the buffer's own file is unchanged.
