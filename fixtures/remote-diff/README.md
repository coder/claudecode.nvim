# `remote-diff` fixture — repro for issue #248

Reproduces the behaviour behind
[#248 "Close diff handled by remote control"](https://github.com/coder/claudecode.nvim/issues/248):
diffs Claude opens in Neovim (via the `openDiff` MCP tool) **stay open forever**
when they are accepted/rejected somewhere other than this Neovim instance
(e.g. Claude "remote control" on a phone), or when the Claude session that
opened them goes away without closing them.

This fixture is like the generic [`repro`](../repro) fixture but:

- keeps logging at `warn` (so the diff UI is clean for screenshots / automation —
  the `repro` fixture's `debug` level spams the message area and triggers
  hit-enter prompts), and
- adds a `:DiffState` / `:DiffStateFile` inspector that prints how many windows
  are open and how many diffs the diff module still considers **active/pending**.

## Files

- `init.lua` — minimal claudecode.nvim config + `:DiffState` inspector.
- `example/{a.txt,b.txt,c.lua}` — sample files to diff against.

## Quick start

```sh
# Terminal 1 — the editor under test:
source fixtures/nvim-aliases.sh
vv remote-diff
#   (equivalently: NVIM_APPNAME=remote-diff XDG_CONFIG_HOME=fixtures nvim a.txt)
# The server auto-starts; check the lock file exists:
#   ls ~/.claude/ide/*.lock

# Terminal 2 — play the role of Claude over the MCP socket:
scripts/repro_issue_248.sh            # open 3 diffs, then DISCONNECT (no close_tab)
```

Now back in Neovim run `:DiffState`. With the #248 fix you will see:

```
windows=1  active_diffs=0
```

The client went away, and `on_disconnect` automatically closed the diffs it had
opened. **Before the fix** the diff windows lingered (`windows=6 active_diffs=3`,
all `[pending]`) because teardown depended entirely on a `close_tab` the departed
client never sent — that was the bug.

`scripts/repro_issue_248.sh --cleanup` instead sends `closeAllDiffTabs`, which now
drains the diff registry (resolving pending diffs), so `:DiffState` likewise shows
`active_diffs=0` — before the fix it closed the windows but left `active_diffs > 0`.

## Verifying with the _real_ Claude CLI

The synthetic script is convenient, but the same leak happens with the real CLI:

```sh
# Point a real Claude at this Neovim's MCP server (use the port from the lock file):
PORT=$(basename "$(ls ~/.claude/ide/*.lock | head -1)" .lock)
cd "$(jq -r .workspaceFolders[0] ~/.claude/ide/$PORT.lock)"
ENABLE_IDE_INTEGRATION=true CLAUDE_CODE_SSE_PORT=$PORT claude --ide
```

In Claude, switch **off** auto-accept (Shift+Tab until the mode line is blank —
in auto/accept-edits mode Claude edits files directly and never uses the IDE
diff), then ask it to edit a file. The diff opens in Neovim (`:DiffState` shows
`active_diffs=1`).

- Accept it (in Neovim **or** in Claude's prompt) → Claude sends `close_tab` →
  the diff closes. This is the normal local flow.
- Instead, **kill the Claude process** (or otherwise resolve the edit out of
  band) before it sends `close_tab` → `:DiffState` still shows the diff. The
  window leaked, exactly as a phone/remote-control resolution would.

## Inspector commands (added by this fixture)

- `:DiffState` — notify window count + active diff tab names/status.
- `:DiffStateFile [path]` — write the same info to a file (for automation;
  defaults to `stdpath('cache')/diff_state.txt`).
- `<leader>as` — run `:DiffState`.
- `<leader>aa` / `<leader>ad` — accept / deny the focused diff.
