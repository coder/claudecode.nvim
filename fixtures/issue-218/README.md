# Fixture: issue #218 — Neovim crashed accepting a new-file markdown diff with render-markdown.nvim

> [BUG] Neovim crashes when accepting new file diff with render-markdown.nvim installed
> https://github.com/coder/claudecode.nvim/issues/218

On the builds the report came from, accepting (`:w`) a **new-file** diff whose proposed
buffer is **markdown**, when the diff was opened in a **new tab**
(`diff_opts.open_in_new_tab = true`) and **render-markdown.nvim** was installed,
abnormally terminated Neovim. Existing-file diffs were fine — only new files (the
original side is an empty buffer, so every proposed line is a diff "add"). This
fixture sets up that state. Whether a given build still crashes is what it checks.

This fixture mirrors the reporter's minimal `repro.lua` (snacks.nvim +
claudecode.nvim + render-markdown.nvim) but loads the **local** claudecode.nvim
checkout (resolved in `lua/config/lazy.lua`), so it exercises this repo's code.

## Set up the state (no real Claude needed)

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
3. **On a build that still crashes, Neovim disappears.** On the builds that crashed,
   the symptom was either a `SIGSEGV` (raw exit `139`, what the reporter saw) or an
   abnormal exit `0` with no `VimLeave` — both are the same memory-unsafety bug. If
   Neovim stays open and the diff closes, this build did not crash.

`:Repro218Reset` restores a single clean tab if you ran the setup but did not press
`:w`.

### Scripted / CI-style verification

```sh
# Exit 0 and "#218 REPRODUCED ..." if Neovim terminated on the accept.
# Exit 1 and "NOT reproduced on this build ..." if it kept running.
NVIM_BIN=/path/to/nvim-0.12.x scripts/repro_issue_218.sh

# Control: exit 0 and "without render-markdown the diff accepts cleanly (no crash)."
# Exit 1 if Neovim terminated even without render-markdown.
scripts/repro_issue_218.sh --no-render-markdown
```

The reported crash was in the redraw/teardown path, which does **not** run under
`--headless`, so the driver uses the `agent-tty` CLI to get a real terminal UI.

## Reproduce with the real Claude CLI (faithful to the report)

1. `vv issue-218`, then open the Claude terminal (`<C-,>` / `:ClaudeCode`).
2. **Turn off auto-accept** (`shift+tab` until the "auto mode" indicator is gone) —
   in auto mode Claude writes files directly and never sends `openDiff`.
3. Ask Claude to create a new `.md` file (e.g. _"create demo.md with a heading, a
   list, a code block and a table using the Write tool"_).
4. When the diff opens, with the cursor in the proposed pane, press `:w`.

## Root cause (as found for the report)

On accept, claudecode resolves the diff and the Claude CLI sends `close_tab`, which
runs `diff.close_diff_by_tab_name` → `_cleanup_diff_state`. For the
`open_in_new_tab` path this executes `vim.cmd("tabclose")` on the tab whose windows
are **still in diff mode**, while render-markdown.nvim is attached to the markdown
proposed buffer and the Claude terminal is open in the other tab. That `:tabclose`
was where Neovim died (the surrounding `pcall` could not catch it — it was a C-level
abnormal termination, not a Lua error, and `VimLeave` never fired).

Isolation results on a build that crashed:

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

Reproduced when the report was investigated, on: Neovim 0.11.0 (abnormal exit 0) and
Neovim 0.12.3 (SIGSEGV 139), render-markdown.nvim 8.12.0 and 8.13.0, and the
claudecode.nvim `main` of that time. Run `scripts/repro_issue_218.sh` to find out
whether your build and checkout still crash.
