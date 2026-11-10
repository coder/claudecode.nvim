# Close diffs in bulk

Claude can close every open diff with the `closeAllDiffTabs` tool, and the user can clear unanswered proposals with `:ClaudeCodeCloseAllDiffs`. Every still-unanswered openDiff call gets `DIFF_REJECTED`. The user command also finishes diffs the user already accepted: when the file does not hold the accepted text yet, it puts the text into the file's buffer as unsaved changes, then closes the diff. The plugin never writes the file.

## Sub-features

- `close-all-tool` closes every diff, answered or not, and answers `CLOSED_<n>_DIFF_TABS`.
- `close-all-rejects` answers each pending openDiff call with `DIFF_REJECTED` when its diff is closed in bulk.
- `close-pending-command` rejects and closes unanswered diffs on `:ClaudeCodeCloseAllDiffs` and reports the count. It also closes rejected diffs that Claude did not close. With no Claude diff open, it says `No Claude diffs to close`.
- `close-command-hands-saved` closes an accepted (`:w`) diff on `:ClaudeCodeCloseAllDiffs` and leaves its text in the file's buffer, unsaved. The text takes the buffer's `'fileformat'` and `'bomb'`. It keeps the diff open, and names the reason, while that buffer already has unsaved changes, cannot be written, or refuses the text. When Claude already wrote the accepted text to the file, it closes the diff, reloads the buffer, and says `Closed 1 accepted Claude diff(s). Their files hold the accepted text.`
- `close-keeps-other-client-saved` leaves a diff the user accepted for another client open on `closeAllDiffTabs` and `close_tab`.

## How to get to it (user POV)

- Claude calls `closeAllDiffTabs`.
- The user runs `:ClaudeCodeCloseAllDiffs`.

## Driving it with vcn.sh

Preconditions:

- Baseline launch with `hello.txt` open and `$V doctor` all `ok`.

Steps:

- **Nothing to close.** Run `$V keys ':ClaudeCodeCloseAllDiffs' Enter`. `$V expr 'execute("messages")'` ends with `No Claude diffs to close`.
- **Open two diffs.** Run `$V tool x1 openDiff "$(jq -nc --arg p "$WORK/hello.txt" '{old_file_path:$p,new_file_path:$p,new_file_contents:"x\n",tab_name:"✻ [Claude Code] hello.txt (x1) ⧉"}')"`, wait with `$V until "bufname() =~# '(x1) ⧉ (proposed)$'" 1`, then the same for `$WORK/other.txt` with id `x2` and tab `✻ [Claude Code] other.txt (x2) ⧉`. `$V expr "tabpagenr('\$')"` prints `2`. Run `$V capture close-all-tool-before` and `$V screenshot close-all-tool-before` now.
- **Close all as Claude.** Run `$V tool x3 closeAllDiffTabs` and `$V await x3`. The answer text is `CLOSED_2_DIFF_TABS`. `$V await x1` and `$V await x2` each print `DIFF_REJECTED` and their tab name. `$V expr "tabpagenr('\$') . winnr('\$') . bufname()"` prints `11hello.txt`. Run `$V capture close-all-tool-after` and `$V screenshot close-all-tool-after`.
- **Close pending as the user.** Open a diff with id `y1` and tab `✻ [Claude Code] hello.txt (y1) ⧉`, using the `x1` command with `y1` in place of `x1`, then run `$V keys ':ClaudeCodeCloseAllDiffs' Enter` and `$V await y1 3`. The answer is `DIFF_REJECTED`. `$V expr 'execute("messages")'` ends with `Closed 1 pending Claude diff(s)`.
- **Finish an accepted diff.** Open a diff with id `y2` and tab `✻ [Claude Code] hello.txt (y2) ⧉` the same way, accept it with `$V keys ':w' Enter` and `$V await y2` (`FILE_SAVED`), then run `$V keys ':ClaudeCodeCloseAllDiffs' Enter`. The messages end with `The accepted Claude edits for hello.txt are in its buffer, not saved: :w writes them, :e! drops them`. `$V expr "winnr('\$')"` prints `1`, `$V expr "getbufvar(bufnr('hello.txt'), '&modified') . join(getbufline(bufnr('hello.txt'), 1, '\$'), '|')"` prints `1x`, and `sha256sum "$WORK/hello.txt"` is unchanged. Drop the text with `$V keys ':buffer hello.txt' Enter ':e!' Enter`, so the next step can open a diff on `hello.txt`.
- **Finish a diff Claude already wrote.** Open a diff for `$WORK/other.txt` with id `w1`, new contents `z\n`, and tab `✻ [Claude Code] other.txt (w1) ⧉`. Accept it with `$V keys ':w' Enter` and `$V await w1 > "$OUT/w1.json"`, then write the answer as Claude: `jq -j '.result.content[1].text' "$OUT/w1.json" > "$WORK/other.txt"`. Run `$V keys ':ClaudeCodeCloseAllDiffs' Enter`. The messages end with `Closed 1 accepted Claude diff(s). Their files hold the accepted text.`, `$V until "join(getbufline(bufnr('other.txt'), 1, '\$'), '|')" z` passes, and `$V expr "winnr('\$') . getbufvar(bufnr('other.txt'), '&modified')"` prints `10`. Return with `$V keys ':buffer hello.txt' Enter`.
- **Keep another client's accepted diff.** Run `VCN_CLIENT=b $V connect`. Open a diff as the launch client with id `z1` and tab `✻ [Claude Code] hello.txt (z1) ⧉`, accept it with `$V keys ':w' Enter` and `$V await z1` (`FILE_SAVED`), then run `$V disconnect`. `VCN_CLIENT=b $V tool z2 closeAllDiffTabs` and `VCN_CLIENT=b $V await z2` answer `CLOSED_0_DIFF_TABS`. `VCN_CLIENT=b $V tool z3 close_tab '{"tab_name":"✻ [Claude Code] hello.txt (z1) ⧉"}'` and `VCN_CLIENT=b $V await z3` answer `TAB_CLOSED`, and the diff stays open: `$V expr "winnr('\$')"` still prints `2`.
- **Proof.** Keep the `close-all-tool-before` and `-after` captures, then run `$V record close-diffs`. Keep the `x1`, `x2`, and `x3` answers from `$OUT/ws-in.jsonl`.

## Gotchas

- While a file's buffer has unsaved changes, `openDiff` on that file fails with error `-32000` `Diff setup failed` (its `data` says `Cannot create diff: file has unsaved changes`) and Neovim waits at `Press ENTER`, and `:ClaudeCodeCloseAllDiffs` keeps an accepted diff of that file open.
- `closeAllDiffTabs` also closes the caller's own accepted diffs. Claude calls it only after writing accepted files, so a recipe that skips the write loses the edits.
- The second diff opens in a new tab page because the first one occupies the current tab.
- The user command reports through `:messages`, not through the client. Read it with `$V expr 'execute("messages")'`.
- When the command reports two lines, for example `Closed 1 pending Claude diff(s)` and `Closed 1 rejected Claude diff(s)`, Neovim waits at `Press ENTER` and RPC stops answering. Run `$V capture <name>` and `$V keys Enter` before the next `$V await` or `$V expr`.
