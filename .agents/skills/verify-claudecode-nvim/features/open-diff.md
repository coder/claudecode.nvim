# Review a proposed diff

Claude proposes new file contents with the `openDiff` tool. Neovim shows the current file next to the proposal, and the tool call stays unanswered until the user accepts (the response carries the accepted text, edits included) or rejects. Claude then writes the file and calls `close_tab`, which closes the diff and reloads the buffer.

## Sub-features

- `diff-open` shows the file and the proposal side by side with focus in the proposal.
- `diff-block` leaves the openDiff call unanswered until the user acts.
- `diff-accept-write` answers `FILE_SAVED` plus the proposal text, user edits included, when the user runs `:w` in the proposal. The file on disk stays unchanged.
- `diff-accept-command` answers `FILE_SAVED` when the user runs `:ClaudeCodeDiffAccept`.
- `diff-reject-quit` answers `DIFF_REJECTED` plus the tab name when the user closes the proposal with `:q`.
- `diff-reject-command` answers `DIFF_REJECTED` when the user runs `:ClaudeCodeDiffDeny`.
- `diff-reject-leave` answers `DIFF_REJECTED` plus the tab name when the user switches the proposal window to another buffer, for example with `:e other.txt`.
- `diff-finalize` closes the diff windows on `close_tab` and shows the file as Claude wrote it.
- `diff-new-file` shows a proposal for a path that does not exist as `<tab_name> (NEW FILE - proposed)` next to an empty `<path> (NEW FILE)` buffer. A reject closes it without `close_tab`, and no file is created.
- `diff-refuse-unsaved` answers error `-32000` `Diff setup failed` when the file's buffer has unsaved changes. The error `data` says `Cannot create diff: file has unsaved changes`.
- `diff-new-tab-mode` leaves the cursor in the proposal, in Normal mode, for every diff that opens in a new tab while the Claude terminal is open.

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
- **Finalize.** Claude writes the answer and closes the tab. Run `jq -j '.result.content[1].text' "$OUT/diff-accept-write-response.json" > "$WORK/hello.txt"`, then `$V tool c1 close_tab '{"tab_name":"✻ [Claude Code] hello.txt (d1) ⧉"}'` and `$V await c1`. The answer text is `TAB_CLOSED`. `$V until "winnr('\$') . &diff . bufname()" 10hello.txt` and `$V until "join(getline(1, '\$'), '|')" 'alpha|BETA|GAMMA user edit'` pass. The buffer reloads about 100 ms after `close_tab` answers, so wait for the text with `until`.
- **Accept with the command.** Open a diff with id `d2` and tab `✻ [Claude Code] hello.txt (d2) ⧉` as in the first step, then run `$V keys ':ClaudeCodeDiffAccept' Enter` and `$V await d2`. The answer is `FILE_SAVED` with the proposed text. Both windows stay until `close_tab`. Close them with `$V tool c2 close_tab '{"tab_name":"✻ [Claude Code] hello.txt (d2) ⧉"}'`, so the next diff opens in this tab page.
- **Reject with `:q`.** Open a diff with id `d3`, then run `$V keys ':q' Enter` and `$V await d3`. The answer is `DIFF_REJECTED`, then the tab name. `$V expr "winnr('\$')"` prints `1`. `$V tool c3 close_tab '{"tab_name":"✻ [Claude Code] hello.txt (d3) ⧉"}'` and `$V await c3` answer `TAB_CLOSED`.
- **Reject by leaving the proposal.** Open a diff with id `d3b`, then run `$V keys ':e other.txt' Enter` and `$V await d3b`. The answer is `DIFF_REJECTED`, then the tab name. The window now shows `other.txt`. Close the diff with `$V tool c3b close_tab '{"tab_name":"✻ [Claude Code] hello.txt (d3b) ⧉"}'` and `$V await c3b`.
- **Reject with the command.** Open a diff with id `d4`, then run `$V keys ':ClaudeCodeDiffDeny' Enter` and `$V await d4`. The answer is `DIFF_REJECTED`, then the tab name. `$V expr "winnr('\$')"` prints `2` until `close_tab`. Close it with `$V tool c4 close_tab '{"tab_name":"✻ [Claude Code] hello.txt (d4) ⧉"}'`, `$V await c4`, and `$V until "winnr('\$')" 1`.
- **Reuse a tab name.** Open a diff with id `d5` and tab `✻ [Claude Code] hello.txt (d5) ⧉`, then send openDiff id `d6` with the same `tab_name`. `$V await d5` answers `DIFF_REJECTED`, and the d6 proposal replaces it.
- **Close a pending diff.** With d6 still unanswered, run `$V tool c6 close_tab '{"tab_name":"✻ [Claude Code] hello.txt (d5) ⧉"}'`. It answers `TAB_CLOSED`, `$V await d6` answers `DIFF_REJECTED`, and `$V until "winnr('\$') . &diff" 10` passes.
- **Refuse an unsaved buffer.** Run `$V keys 'A!' Escape` and `$V until 'mode() . &modified' n1`, then open a diff with id `e1`. `$V await e1 | jq -c .error` shows code `-32000`, message `Diff setup failed`, and `data` containing `file has unsaved changes`. Neovim now waits at `Press ENTER`: run `$V capture diff-refuse-unsaved`, then `$V keys ':e!' Enter` to dismiss it and drop the change.
- **Propose a new file.** Send openDiff id `n1` for `$WORK/new.txt` (both paths) with tab `✻ [Claude Code] new.txt (n1) ⧉`. `$V until "bufname() ==# '✻ [Claude Code] new.txt (n1) ⧉ (NEW FILE - proposed)'" 1` passes, and `$V expr "winnr('\$')"` prints `3`. `$V keys ':ClaudeCodeDiffDeny' Enter` answers `DIFF_REJECTED`, `$V until "winnr('\$')" 1` passes with no `close_tab`, and `$WORK/new.txt` does not exist.
- **Check the mode of diffs in new tabs.** On a fresh launch with `VCN_SETUP='{"terminal_cmd":"sleep 300","terminal":{"provider":"native"},"diff_opts":{"open_in_new_tab":true}}' $V launch` (add `"layout":"unified"` to `diff_opts` for the unified layout). Run `$V keys ':ClaudeCode' Enter` and `$V until '&buftype' terminal`, then `$V keys "Ctrl+\\" Ctrl+N` and `$V keys ':wincmd p' Enter`, so the user is in the editor in Normal mode with the terminal beside it. Open a diff with id `d1` as in the first step and `$V until "bufname() =~# '(d1)' && tabpagenr() == 2" 1`, then `$V until 'mode(1)' n`. Open `d2` for `other.txt` while `d1` is open: `$V until "bufname() =~# '(d2)' && tabpagenr() == 3" 1` and `$V until 'mode(1)' n` pass. A proposal in Insert mode fails the second `until`, and `$V capture` shows `-- INSERT --` on the last screen line. Close both with `close_tab` for `d2`, then `d1`.
- **Proof.** On a fresh launch, run `.agents/skills/verify-claudecode-nvim/scripts/journey-opendiff-accept.sh`. It covers `diff-open`, `diff-block`, `diff-accept-write`, and `diff-finalize`, prints `PASS opendiff-accept`, and writes `opendiff-accept-1-open`, `-2-edited`, `-3-saved`, and `-4-closed` screen captures, PNGs for the first three, `opendiff-accept.webm`, `opendiff-accept-response.json`, and `opendiff-accept-disk.txt` (the file's sha256 before openDiff, after `:w`, and after Claude's write) to `$OUT`.
- **Proof for new tabs.** On a fresh launch as in the previous step, run `.agents/skills/verify-claudecode-nvim/scripts/journey-new-tab-diff-mode.sh`. It covers `diff-new-tab-mode`, prints `PASS new-tab-diff-mode` or `FAIL: <reason>`, and writes `new-tab-diff-mode-1-editor`, `-2-first`, `-3-second` and `-4-closed` screen captures to `$OUT`.

## Gotchas

- `close_tab` closes only the diff whose `tab_name` matches exactly, and never a buffer. `{"tab_name":"hello.txt (z1)"}` for the diff `✻ [Claude Code] hello.txt (z1) ⧉` answers `TAB_CLOSED` and leaves the diff pending. An exact match on a pending diff rejects it: its openDiff call gets `DIFF_REJECTED`.
- A reused `tab_name` replaces the open diff, and the earlier openDiff call gets `DIFF_REJECTED`. Use a new name per call. If the user accepted that diff for another client, the call fails with error `-32000` instead.
- After `:w` the proposal still shows `[+]` and the file is unchanged. That is correct. Only Claude writes the file.
- After `:w` the plugin turns diff mode off in the proposal window, so a screenshot taken then shows no diff highlight. Take the highlight proof before the user accepts.
- `$(...)` drops the trailing newline of the answer text. Compare with `jq -e --arg want "$text" '... == $want'` or write the text with `jq -j`.
- A second diff opened while the first is still showing opens in a new tab page.
- A pending Insert mode starts only after the call that opened the diff returned, and nothing signals that it did not start. Wait for the proposal with `until`, then read `mode(1)` after about half a second, not at once.
- With `terminal.provider = "snacks"` the same checks apply, but the harness installs no snacks.nvim: put a clone on Neovim's `runtimepath` first (the commit that `fixtures/snacks-picker/lazy-lock.json` pins). A Snacks terminal auto-inserts on every `BufEnter`, so it needs no earlier diff to show the failure.
- A refused openDiff (unsaved changes) shows an ERROR message wider than the screen, so Neovim waits at `Press ENTER` and RPC stops answering: `$V doctor` fails its RPC and prompt lines. Capture the screen, then press `Enter` or type a `:` command.
- The `unified` layout (`VCN_SETUP='{"diff_opts":{"layout":"unified"}}'`) shows the file next to one buffer named `<tab_name> (unified diff)`, and `&diff` is `0`. The `(proposed)` checks above do not match there, and these steps change:
  - The buffer is not modifiable. The edit step fails with `E21: Cannot make changes, 'modifiable' is off`, so `:w` answers `FILE_SAVED` with the proposal text and no user edits.
  - The `-` and `+` marks are drawn on screen only. `$V expr "join(getline(1, '\$'), '|')"` prints both versions, `alpha|beta|BETA|gamma`.
  - A second unified diff opens in the same tab page as a third window, not in a new tab page.
  - `:q` rejects as in the split layout: `$V keys ':q' Enter`, then `$V await d3` answers `DIFF_REJECTED` and `$V expr "winnr('\$')"` prints `1`. When the window stays and the screen shows `E37: No write since last change`, the proposal buffer has `'bufhidden'` `wipe` instead of `hide`.
