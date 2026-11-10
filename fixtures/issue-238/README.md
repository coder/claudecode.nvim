# `issue-238` fixture — regression check for issue #238

[#238 "[BUG] Rejecting with `:q` does not work"](https://github.com/coder/claudecode.nvim/issues/238)
reported that `:q` on the proposed window did not reject a Claude diff. The
window closed, but Claude was never told `DIFF_REJECTED`, and with
`open_in_new_tab = true` the diff tab stayed open. `<leader>ad`
(`:ClaudeCodeDiffDeny`) worked. #266 fixed it: `:q` now rejects the diff in both
layouts. This fixture keeps the reporter's setup so you can check that by hand.

This fixture uses the reporter's exact config:

- `terminal.provider = "none"` (Claude runs in an external terminal, e.g.
  sidekick.nvim, so claudecode manages no terminal of its own), and
- `diff_opts = { layout = "vertical", open_in_new_tab = true }`.

It mirrors [`remote-diff`](../remote-diff) but adds a JSON `:DiffStateFile`
inspector that records window/tab counts, each diff's status, and the proposed
buffer's `bufhidden`.

> Set `REPRO238_NEW_TAB=0` to launch in the **default** same-tab layout.

## Files

- `init.lua` — claudecode.nvim config matching the issue + `:DiffState`/`:DiffStateFile`.
- `example/target.txt` — a sample file to diff against.

## How `:q` rejects the diff

The proposed buffer is created with `vim.api.nvim_create_buf(false, true)`
(a scratch buffer ⇒ `bufhidden = "hide"`), so `:q` only **hides** it. The
`BufDelete` / `BufUnload` / `BufWipeout` autocmds do not fire for a hidden
buffer, and before #266 they were the only path to `_resolve_diff_as_rejected`.
Now a `WinClosed` autocmd rejects the diff when the last window that shows the
proposed buffer closes. If you split the proposed buffer, in this tab or
another, the diff stays pending until the last copy closes.

## Quick start — headless check (no WebSocket needed)

Drives the real `diff.lua` and performs a genuine `:q`, for both
`open_in_new_tab` layouts, a split proposed buffer, and a new file. CI runs this
command on Neovim stable and v0.8.0 (`nvim -l` needs 0.9 and hangs on 0.8):

```sh
nvim --headless -u NONE -c "luafile scripts/repro_issue_238.lua" -c "cquit 2"; echo "exit: $?"
```

Exit code **0** = fixed, **1** = the bug is back, **2** = the script raised an
error before its verdict. On current code it prints:

```
[default config (open_in_new_tab=false)]
  proposed buffer bufhidden = "hide"
  after :q -> rejected=true  status=rejected  proposed_buf_still_loaded=true  tabpages 1->1
  => OK: `:q` resolved the diff as DIFF_REJECTED

[reporter config (open_in_new_tab=true)]
  proposed buffer bufhidden = "hide"
  after :q -> rejected=true  status=rejected  proposed_buf_still_loaded=true  tabpages 2->2
  => OK: `:q` resolved the diff as DIFF_REJECTED
...
== verdict ==
FIXED: `:q` rejects the Claude diff in every scenario.
```

## Quick start — live, playing the role of Claude over MCP

```sh
# Terminal 1 — the editor under test:
source fixtures/nvim-aliases.sh
vv issue-238 issue-238/example/target.txt
#   (equivalently: NVIM_APPNAME=issue-238 XDG_CONFIG_HOME="$PWD/fixtures" nvim fixtures/issue-238/example/target.txt)
#   (Neovim 0.8 ignores NVIM_APPNAME; there, run:
#    XDG_CONFIG_HOME="$PWD/fixtures" nvim -u fixtures/issue-238/init.lua fixtures/issue-238/example/target.txt)
# The fixture starts the server; check the lock file:  ls ~/.claude/ide/*.lock

# Terminal 2 — open a diff and HOLD the socket open while you reject in Neovim:
scripts/repro_issue_238.sh --file "$PWD/fixtures/issue-238/example/target.txt" --hold 30
```

A diff opens in a new tab. In Neovim, reject it with **`:q`**. Then:

- The Terminal-2 script prints `RESULT: DIFF_REJECTED was received — rejection WORKED.`
- `:DiffState` shows the diff as `[rejected]`. The diff tab stays open, because
  this script sends no `close_tab` after the answer.

`:ClaudeCodeDiffDeny` (or `<leader>ad`) gives the same result.

> If `websocat` is a `mise` shim that refuses to run in this directory, pass the
> real binary: `WEBSOCAT="$(mise which websocat)" scripts/repro_issue_238.sh ...`.

## Inspector commands (added by this fixture)

- `:DiffState` — notify window/tab count + each active diff's status, `created_new_tab`, and proposed `bufhidden`.
- `:DiffStateFile [path]` — write the same info as JSON (for automation; defaults to `stdpath('cache')/diff_state.json`).
- `<leader>as` — run `:DiffState`.
- `<leader>aa` / `<leader>ad` — accept / deny the focused diff.
