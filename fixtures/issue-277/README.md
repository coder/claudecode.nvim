# Fixture: issue #277 — closeAllDiffTabs destroys foreign diffs

Reproduction environment for
[#277 "[BUG] closeAllDiffTabs closes all diff-mode windows, destroying unrelated diffs (diffview.nvim)"](https://github.com/coder/claudecode.nvim/issues/277).

Two defects:

1. `tools/close_all_diff_tabs.lua` closes **every** window with `&diff` set (and
   force-deletes `%.diff$` / `diff://` / `fugitive://` buffers) with no check
   that claudecode created them. The Claude CLI invokes `closeAllDiffTabs` at
   the **start of each user turn** when an IDE is connected (verified against
   CLI 2.1.175), so any diffview.nvim / fugitive / native vimdiff layout that is
   open when you submit a prompt gets destroyed.
2. `find_main_editor_window()` (in `tools/open_file.lua` and `diff.lua`) does
   not exclude `&diff` windows, so `openFile`/`openDiff` can `:edit` into one
   half of a foreign diff, corrupting it (the new buffer joins the diff).

## Scripted reproduction

```bash
scripts/repro_issue_277.sh
```

Drives a real Neovim TUI under agent-tty, opens diffview/native diffs, then
sends the same MCP `tools/call` requests the Claude CLI sends. Prints
`REPRODUCED:`/`NOT REPRODUCED:` per phase; exits 0 when all three defects
reproduce.

## Manual reproduction

```bash
source fixtures/nvim-aliases.sh && vv issue-277  # cwd must be a git repo with changes
```

1. `:DiffviewOpen` — side-by-side diff appears (2 windows with `&diff` + file panel).
2. Connect Claude (`:ClaudeCode`, or any client with the lock-file token).
3. Submit any prompt (or send `closeAllDiffTabs` by hand).
4. Both diff windows close; only the Diffview panel survives. `<leader>aw`
   shows the diff-window count; `:ReproState` dumps per-window state.

`:ReproNativeDiff <a> <b>` opens a plugin-free native vimdiff for the same
experiment (no diffview involved).

## Notes

- diffview.nvim is cloned into `stdpath("data")/diffview.nvim`
  (`~/.local/share/issue-277/`) on first start.
- The fixture exposes `v:lua.Repro277State()`, `v:lua.Repro277DiffWinCount()`
  and `v:lua.Repro277Server()` for `--remote-expr` scripting.
