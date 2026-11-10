# snacks-picker fixture — triage for issue #192

Reproduces and explores [#192](https://github.com/coder/claudecode.nvim/issues/192):
make adding the **highlighted/selected file in a snacks.nvim picker** to Claude's
context work, instead of failing with:

```
[ClaudeCode] [command] [ERROR] ClaudeCodeTreeAdd: Not in a supported tree buffer (current filetype: snacks_picker_list)
```

Unlike the tree-explorer integrations (`nvim-tree`, `neo-tree`, `oil`,
`mini.files`, `netrw`), a snacks **picker** is a modal fuzzy finder. Its window
layout is:

| window | filetype              | buftype  | usual focus                       |
| ------ | --------------------- | -------- | --------------------------------- |
| box    | `snacks_layout_box`   | `nofile` | —                                 |
| list   | `snacks_picker_list`  | `nofile` | only when you `<Tab>`/cycle to it |
| input  | `snacks_picker_input` | `prompt` | **default (insert mode)**         |

`:ClaudeCodeTreeAdd` only sees `snacks_picker_list` when the **list** window is
focused — but the picker normally keeps focus in the **input** box. That is why
the idiomatic fix is an in-picker _action bound to a key_, not an ex-command.

Note: `Snacks.explorer()` is built on the picker and also uses the
`snacks_picker_list` filetype, so the same code path covers both.

## Run it

```bash
source fixtures/nvim-aliases.sh
vv snacks-picker
```

Then `:ClaudeCodeStart` (or it auto-starts), and:

- `<leader>ff` → files picker, `<leader>fg` → grep picker.

### Path A — zero-change WORKAROUND (works on stock claudecode.nvim)

`lua/plugins/snacks.lua` registers a custom picker action `claude_add` bound to
`<c-o>` in both the input and list windows. From the picker (input box, insert
mode):

1. Type to filter; optionally `<Tab>` to multi-select several files.
2. Press `<c-o>` → the selected files (or the one under the cursor) are sent to
   Claude via the public `require("claudecode").send_at_mention()` API, and the
   picker closes.

This needs **no changes to claudecode.nvim**. It mirrors how the community
`claude-fzf.nvim` plugin integrates fzf-lua.

### Path B — built-in command path

The in-core `snacks_picker_list` handler (`integrations._get_snacks_picker_selection`)
makes `:ClaudeCodeTreeAdd` work when the list window is focused:

1. Open a picker, `<Tab>` to focus/cycle to the **list** window (filetype becomes
   `snacks_picker_list`).
2. `:ClaudeCodeTreeAdd` (or `<leader>at`) → selected/cursor files are added.

## Deterministic, headless proof (no Claude client needed)

The behavior was validated headlessly:

```text
# Without the snacks_picker_list handler (the issue #192 state), list focused:
focused_filetype:  snacks_picker_list
dispatch_error:    Not in a supported tree buffer (current filetype: snacks_picker_list)

# With the in-core handler, 2 files multi-selected:
handler_basenames: alpha.lua,beta.lua
dispatch_files: 2   err: nil

# Key-bound action (Path A), 2 files multi-selected:
send_at_mention_results: alpha.lua=true,beta.lua=true
```

To reproduce headlessly, a small throwaway harness (not committed) opens a picker
with `Snacks.picker.files({ cwd = ... })`, `vim.wait`s until
`Snacks.picker.get()` returns a picker with items, focuses the list window, then
calls `require("claudecode.integrations").get_selected_files_from_tree()` and
inspects the returned paths. The committed unit test
`tests/unit/snacks_picker_integration_spec.lua` covers the same logic
deterministically with mocked snacks.
