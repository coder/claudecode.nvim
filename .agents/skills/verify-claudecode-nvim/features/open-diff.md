# Review a proposed diff

Claude proposes new file contents with the `openDiff` tool. Neovim shows the current file next to the proposal, and the tool call stays unanswered until the user accepts (the response carries the accepted text, edits included) or rejects. Claude then writes the file and calls `close_tab`, which closes the diff and reloads the buffer.

## Sub-features

- `diff-open` shows the file and the proposal side by side with focus in the proposal.
- `diff-block` leaves the openDiff call unanswered until the user acts.
- `diff-accept-write` answers `FILE_SAVED` plus the proposal text, user edits included, when the user runs `:w` in the proposal. The file on disk stays unchanged.
- `diff-accept-command` answers `FILE_SAVED` when the user runs `:ClaudeCodeDiffAccept`.
- `diff-reject-quit` answers `DIFF_REJECTED` plus the tab name when the user closes the proposal with `:q`.
- `diff-reject-command` answers `DIFF_REJECTED` when the user runs `:ClaudeCodeDiffDeny`.
- `diff-finalize` closes the diff windows on `close_tab` and shows the file as Claude wrote it.

## How to get to it (user POV)

- Claude calls `openDiff` while the user works in Neovim.
- In the proposal window, the user runs `:w` (accept), `:ClaudeCodeDiffAccept` (accept), `:q` (reject), or `:ClaudeCodeDiffDeny` (reject).
- Claude calls `close_tab` with the same `tab_name` after it has the answer.

## Driving it with vcn.sh

Preconditions:

- Baseline launch with `hello.txt` open and `$V doctor` all `ok`.
- `sha256sum "$WORK/hello.txt"` recorded before the first step.

Steps:

- **Open the diff.** Claude proposes `BETA` on line 2. Run `$V tool d1 openDiff "$(jq -nc --arg p "$WORK/hello.txt" '{old_file_path:$p,new_file_path:$p,new_file_contents:"alpha\nBETA\ngamma\n",tab_name:"✻ [Claude Code] hello.txt (d1) ⧉"}')"` and `$V until "bufname() ==# '✻ [Claude Code] hello.txt (d1) ⧉ (proposed)' && &diff" 1`. `$V capture diff-open` shows `hello.txt` on the left and the proposal with `BETA` on the right. `$V screenshot diff-open` shows line 2 highlighted on both sides.
- **Prove it blocks.** Run `$V await d1 2`. It exits 1 with `no response for id d1 within 2s`.
- **Edit and accept with `:w`.** Change line 3 of the proposal and save. Run `$V keys ':3' Enter cc`, `$V keys -l 'GAMMA user edit'`, `$V keys Escape`, `$V until 'mode() . getline(3)' 'nGAMMA user edit'`, then `$V keys ':w' Enter` and `$V await d1 10 > "$OUT/diff-accept-write-response.json"`. `result.content` is `FILE_SAVED`, then `alpha\nBETA\nGAMMA user edit\n`. `sha256sum "$WORK/hello.txt"` still matches the precondition.
- **Finalize.** Claude writes the answer and closes the tab. Run `jq -j '.result.content[1].text' "$OUT/diff-accept-write-response.json" > "$WORK/hello.txt"`, then `$V tool c1 close_tab '{"tab_name":"✻ [Claude Code] hello.txt (d1) ⧉"}'` and `$V await c1`. The answer text is `TAB_CLOSED`. `$V until "winnr('\$') . &diff . bufname()" 10hello.txt` passes, and `$V expr "join(getline(1, '\$'), '|')"` prints `alpha|BETA|GAMMA user edit`.
- **Accept with the command.** Open a diff with id `d2` and tab `✻ [Claude Code] hello.txt (d2) ⧉` as in the first step, then run `$V keys ':ClaudeCodeDiffAccept' Enter` and `$V await d2`. The answer is `FILE_SAVED` with the proposed text. Both windows stay until `close_tab`.
- **Reject with `:q`.** Open a diff with id `d3`, then run `$V keys ':q' Enter` and `$V await d3`. The answer is `DIFF_REJECTED`, then the tab name. `$V expr "winnr('\$')"` prints `1`. `close_tab` for that tab answers `TAB_CLOSED`.
- **Reject with the command.** Open a diff with id `d4`, then run `$V keys ':ClaudeCodeDiffDeny' Enter` and `$V await d4`. The answer is `DIFF_REJECTED`, then the tab name. `$V expr "winnr('\$')"` prints `2` until `close_tab`.
- **Proof.** On a fresh launch, run `.agents/skills/verify-claudecode-nvim/scripts/journey-opendiff-accept.sh`. It covers `diff-open`, `diff-block`, `diff-accept-write`, and `diff-finalize`, prints `PASS opendiff-accept`, and writes `opendiff-accept-1-open`, `-2-edited`, `-3-saved`, and `-4-closed` screen captures, PNGs for the first three, `opendiff-accept.webm`, `opendiff-accept-response.json`, and `opendiff-accept-disk.txt` (the file's sha256 before openDiff, after `:w`, and after Claude's write) to `$OUT`.

## Gotchas

- `close_tab` finds the diff only when `tab_name` contains `✻` and `⧉`. Other names are matched as buffer names instead. `{"tab_name":"hello.txt (z1)"}` answered a `result` holding `Failed to close buffer ... Failed to unload buffer.`, left the diff pending, and stopped nvim at `Press ENTER` (observed 2026-10-31).
- A reused `tab_name` replaces the open diff. Use a new name per call.
- After `:w` the proposal still shows `[+]` and the file is unchanged. That is correct. Only Claude writes the file.
- After `:w` the plugin turns diff mode off in the proposal window, so a screenshot taken then shows no diff highlight. Take the highlight proof before the user accepts.
- `$(...)` drops the trailing newline of the answer text. Compare with `jq -e --arg want "$text" '... == $want'` or write the text with `jq -j`.
- A second diff opened while the first is still showing opens in a new tab page.
- The `unified` layout (`VCN_SETUP='{"diff_opts":{"layout":"unified"}}'`) shows the file next to a buffer named `<tab_name> (unified diff)` with `-` and `+` lines, and `&diff` is `0`. The `(proposed)` checks above do not match there. Rerun every step with that buffer name instead of assuming the vertical results carry over.
