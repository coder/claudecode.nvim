# Fixture: issue #218 — Neovim crashes accepting a new-file markdown diff with render-markdown.nvim

> [BUG] Neovim crashes when accepting new file diff with render-markdown.nvim installed
> https://github.com/coder/claudecode.nvim/issues/218

Accepting (`:w`) a **new-file** diff whose proposed buffer is **markdown**, when the
diff was opened in a **new tab** (`diff_opts.open_in_new_tab = true`) and
**render-markdown.nvim** is installed, abnormally terminates Neovim. Existing-file
diffs are fine — only new files (the original side is an empty buffer, so every
proposed line is a diff "add").

This fixture mirrors the reporter's minimal `repro.lua` (snacks.nvim +
claudecode.nvim + render-markdown.nvim) but loads the **local** claudecode.nvim
checkout (resolved in `lua/config/lazy.lua`), so it exercises this repo's code.

## Reproduce (no real Claude needed)

```sh
source fixtures/nvim-aliases.sh
vv issue-218
```

Then in Neovim:

1. `:Repro218` — opens a harmless Claude terminal split and a **new-file markdown
   diff in a new tab**, leaving the cursor in the proposed (right) pane. It drives
   the same `openDiff` coroutine flow the MCP server uses and wires the post-accept
   `close_tab` exactly as the Claude CLI would.
2. Press `:w` to accept.
3. **Neovim disappears.** Depending on the Neovim build the symptom is either a
   `SIGSEGV` (raw exit `139`, what the reporter saw) or an abnormal exit `0` with
   no `VimLeave` — both are the same memory-unsafety bug.

`:Repro218Reset` restores a single clean tab if you ran the setup but did not press
`:w`.

### Scripted / CI-style verification

```sh
# Expect: "#218 REPRODUCED — Neovim SIGSEGV (139) on diff accept."
NVIM_BIN=/path/to/nvim-0.12.x scripts/repro_issue_218.sh

# Control — expect: "without render-markdown the diff accepts cleanly (no crash)."
scripts/repro_issue_218.sh --no-render-markdown
```

The crash lives in the redraw/teardown path, which does **not** run under
`--headless`, so the driver uses the `agent-tty` CLI to get a real terminal UI.

## Reproduce with the real Claude CLI (faithful to the report)

1. `vv issue-218`, then open the Claude terminal (`<C-,>` / `:ClaudeCode`).
2. **Turn off auto-accept** (`shift+tab` until the "auto mode" indicator is gone) —
   in auto mode Claude writes files directly and never sends `openDiff`.
3. Ask Claude to create a new `.md` file (e.g. _"create demo.md with a heading, a
   list, a code block and a table using the Write tool"_).
4. When the diff opens, with the cursor in the proposed pane, press `:w`.

## Root cause (verified)

On accept, claudecode resolves the diff and the Claude CLI sends `close_tab`, which
runs `diff.close_diff_by_tab_name` → `_cleanup_diff_state`. For the
`open_in_new_tab` path this executes `vim.cmd("tabclose")` on the tab whose windows
are **still in diff mode**, while render-markdown.nvim is attached to the markdown
proposed buffer and the Claude terminal is open in the other tab. That `:tabclose`
is where Neovim dies (the surrounding `pcall` cannot catch it — it is a C-level
abnormal termination, not a Lua error, and `VimLeave` never fires).

Confirmed by isolation:

| render-markdown                                      | Claude terminal | outcome on `:w` accept |
| ---------------------------------------------------- | --------------- | ---------------------- |
| installed                                            | open            | **crash** (tabclose)   |
| **removed**                                          | open            | clean teardown         |
| installed                                            | not open        | clean teardown         |
| installed (diff mode turned **off** before teardown) | open            | clean teardown         |

The reporter's workaround — `pcall(vim.cmd, "diffoff")` at the end of the
`BufWriteCmd` callback — works because turning diff mode off before the tab is
closed removes the trigger. A more targeted plugin-side fix is to turn diff mode
off on the diff windows inside `_cleanup_diff_state` **before** `:tabclose`.

Reproduced on: Neovim 0.11.0 (abnormal exit 0) and Neovim 0.12.3 (SIGSEGV 139),
render-markdown.nvim 8.12.0 and 8.13.0, claudecode.nvim current `main`.
