# snacks-explorer fixture — reproduction for issue #236

Reproduces [#236](https://github.com/coder/claudecode.nvim/issues/236): with the
**Snacks Explorer** open (LazyVim's default file explorer), Claude's diff
preview opens in the **wrong window** — it targets/corrupts the explorer sidebar
instead of the main editor. Switching to neo-tree or setting
`diff_opts.open_in_new_tab = true` avoids it.

This fixture mirrors a LazyVim-style setup: `lazy.nvim` + `snacks.nvim` with the
explorer enabled as a left sidebar, plus the local `claudecode.nvim` checkout
(loaded via `dir`, so it also works from a git worktree).

## Run it

```bash
source fixtures/nvim-aliases.sh
# `vv` always cd's to the fixtures/ dir, so pass the file path relative to it.
vv snacks-explorer snacks-explorer/example/sample.txt
```

Inside Neovim (the explorer roots at the `fixtures/` dir — `example/` is in it):

1. `:lua Snacks.explorer()` (or `<leader>e`) to open the explorer sidebar.
2. Start Claude and ask it to **create a new file** or **edit a file that is not
   already open in a window** — e.g. "create `notes.md` with a few lines".
3. Observe the diff: the explorer sidebar gets hijacked / the diff lands in the
   wrong split.

## Reproduce the root cause without Claude

The bug is entirely in window selection (`find_main_editor_window`), so you can
prove it deterministically. With the explorer open and `sample.txt` in the
editor:

```vim
:lua print(vim.bo[vim.api.nvim_win_get_buf(require('claudecode.diff')._find_main_editor_window())].filetype)
```

- **Buggy (before the fix):** prints `snacks_layout_box` — the explorer sidebar.
- **Fixed:** prints the editor's filetype (e.g. `text`).

### Why the explorer is mis-detected

`Snacks.explorer()` (sidebar preset) is **not** a single floating window. It is:

| window | filetype              | buftype  | floating? |
| ------ | --------------------- | -------- | --------- |
| box    | `snacks_layout_box`   | `nofile` | **no**    |
| list   | `snacks_picker_list`  | `nofile` | yes       |
| input  | `snacks_picker_input` | `prompt` | yes       |

`find_main_editor_window` excluded `snacks_picker_list` (PR #165) but **not**
`snacks_layout_box`. The layout box is a non-floating `nofile` split with an
unrecognized filetype, so it passed every check and — being first in the window
list — was returned as the "main editor window". The fix adds
`snacks_layout_box` to the exclusion list.
