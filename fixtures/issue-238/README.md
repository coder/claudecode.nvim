# `issue-238` fixture — repro for issue #238

Reproduces [#238 "[BUG] Rejecting with `:q` does not work"](https://github.com/coder/claudecode.nvim/issues/238):
the README documents two ways to reject a Claude diff — `:q` **or** `<leader>ad`
(`:ClaudeCodeDiffDeny`). The keymap works; **`:q` does not reject**. The proposed
window closes but Claude is never told `DIFF_REJECTED`, and (with
`open_in_new_tab = true`) the diff tab lingers.

This fixture uses the reporter's exact config:

- `terminal.provider = "none"` (Claude runs in an external terminal, e.g.
  sidekick.nvim, so claudecode manages no terminal of its own), and
- `diff_opts = { layout = "vertical", open_in_new_tab = true }`.

It mirrors [`remote-diff`](../remote-diff) but adds a JSON `:DiffStateFile`
inspector that records window/tab counts, each diff's status, **and the proposed
buffer's `bufhidden`** — the smoking gun for this bug.

> Set `REPRO238_NEW_TAB=0` to launch in the **default** same-tab layout and
> confirm the bug is not tab-specific (it reproduces there too — the split just
> silently collapses to the original file).

## Files

- `init.lua` — claudecode.nvim config matching the issue + `:DiffState`/`:DiffStateFile`.
- `example/target.txt` — a sample file to diff against.

## Root cause (verified)

The proposed buffer is created with `vim.api.nvim_create_buf(false, true)`
(a scratch buffer ⇒ `bufhidden = "hide"`) and rejection is wired **only** through
buffer-destruction autocmds (`BufDelete` / `BufUnload` / `BufWipeout` →
`_resolve_diff_as_rejected`). Because `bufhidden = "hide"`, `:q` merely **hides**
the still-loaded buffer instead of destroying it, so none of those autocmds fire
and the diff is never resolved. (`:ClaudeCodeDiffDeny` works because it calls
`_resolve_diff_as_rejected` directly, bypassing the autocmds.)

## Quick start — headless one-liner (no WebSocket needed)

The fastest way to see the bug. Drives the real `diff.lua` and performs a genuine
`:q`, for both `open_in_new_tab` layouts:

```sh
nvim --headless -u NONE -l scripts/repro_issue_238.lua; echo "exit: $?"
```

Exit code **1** = bug reproduced (current code), **0** = fixed. On current code it prints:

```
[default config (open_in_new_tab=false)]
  proposed buffer bufhidden = "hide"
  after :q -> rejected=false  status=pending  proposed_buf_still_loaded=true  tabpages 1->1
  => BUG: `:q` did NOT reject the diff (Claude never receives DIFF_REJECTED)
[reporter config (open_in_new_tab=true)]
  proposed buffer bufhidden = "hide"
  after :q -> rejected=false  status=pending  proposed_buf_still_loaded=true  tabpages 2->2
  => BUG: ...
```

## Quick start — live, playing the role of Claude over MCP

```sh
# Terminal 1 — the editor under test:
source fixtures/nvim-aliases.sh
vv issue-238 example/target.txt
#   (equivalently: NVIM_APPNAME=issue-238 XDG_CONFIG_HOME=fixtures nvim fixtures/issue-238/example/target.txt)
# The server auto-starts; check the lock file:  ls ~/.claude/ide/*.lock

# Terminal 2 — open a diff and HOLD the socket open while you reject in Neovim:
scripts/repro_issue_238.sh --file "$PWD/fixtures/issue-238/example/target.txt" --hold 30
```

A diff opens in a new tab. In Neovim, try to reject it with **`:q`**. Then:

- Run `:DiffState` in Neovim → it still shows the diff as `[pending]`
  (`bufhidden=hide`), and the tab is still open.
- The Terminal-2 script reports `no DIFF_REJECTED / FILE_SAVED in window` — Claude
  never learned the diff was rejected.

Contrast: reject with `:ClaudeCodeDiffDeny` (or `<leader>ad`) instead → the script
prints `DIFF_REJECTED was received` and `:DiffState` shows the diff `[rejected]`.

> If `websocat` is a `mise` shim that refuses to run in this directory, pass the
> real binary: `WEBSOCAT="$(mise which websocat)" scripts/repro_issue_238.sh ...`.

## Inspector commands (added by this fixture)

- `:DiffState` — notify window/tab count + each active diff's status, `created_new_tab`, and proposed `bufhidden`.
- `:DiffStateFile [path]` — write the same info as JSON (for automation; defaults to `stdpath('cache')/diff_state.json`).
- `<leader>as` — run `:DiffState`.
- `<leader>aa` / `<leader>ad` — accept / deny the focused diff.
