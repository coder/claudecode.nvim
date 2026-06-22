# Fixture: issue #289 — path-substring tree misclassification

Reproduces [#289](https://github.com/coder/claudecode.nvim/issues/289):

> `ClaudeCodeSend` misclassifies a regular file buffer as a "tree buffer" when
> the **file path** (not filetype) contains the substring `neo-tree`,
> `NvimTree`, or `minifiles://`.

## Root cause

`handle_send_normal` and `handle_send_visual` in `lua/claudecode/init.lua`
decide whether the current buffer is a file-explorer ("tree") buffer using both
the filetype **and** a substring match against the buffer **name**:

```lua
local is_tree_buffer = current_ft == "NvimTree"
  or current_ft == "neo-tree"
  or current_ft == "oil"
  or current_ft == "minifiles"
  or current_ft == "netrw"
  or current_ft == "snacks_picker_list"   -- (normal handler only)
  or string.match(current_bufname, "neo%-tree")    -- ← false positive
  or string.match(current_bufname, "NvimTree")     -- ← false positive
  or string.match(current_bufname, "minifiles://")
```

A perfectly ordinary `lua` file whose **path** merely contains one of those
substrings (e.g. a plugin spec named `_neo-tree_.lua`, or anything under a
`nvim-tree-config/` directory) is therefore treated as a tree buffer.

## Files

| File                         | Path contains | Classified as tree? |
| ---------------------------- | ------------- | ------------------- |
| `lua/plugins/_neo-tree_.lua` | `neo-tree`    | **yes (bug)**       |
| `lua/NvimTree_settings.lua`  | `NvimTree`    | **yes (bug)**       |
| `lua/regular_plugin.lua`     | _(none)_      | no (control)        |

All three are plain `filetype=lua` files. Only the path differs.

## Reproduce manually

```bash
source fixtures/nvim-aliases.sh
vv issue-289 'lua/plugins/_neo-tree_.lua'   # AFFECTED
# (or) vv issue-289 'lua/regular_plugin.lua' # CONTROL
```

or directly:

```bash
NVIM_APPNAME=issue-289 XDG_CONFIG_HOME=fixtures \
  nvim fixtures/issue-289/lua/plugins/_neo-tree_.lua
```

Then, in the buffer:

1. **Visual path** (the README-default `<leader>as`, which maps to
   `<cmd>ClaudeCodeSend<cr>` and keeps visual mode): visually select a few lines
   (`Vjj`) and press `<leader>as`.
   → `ClaudeCode Error [ClaudeCode] [command] [ERROR] ClaudeCodeSend_visual->TreeAdd: Not in visual mode (current mode: n)`
2. **Range path**: visually select a few lines, then `:'<,'>ClaudeCodeSend`.
   → `ClaudeCode Error [ClaudeCode] [command] [ERROR] ClaudeCodeSend->TreeAdd: Not in a supported tree buffer (current filetype: lua)`

Doing the same in `regular_plugin.lua` sends the selection with no error.

## Helper commands (provided by this fixture's `init.lua`)

- `:ReproState [path]` — write the current buffer's tree-classification state
  (`filetype`, `bufname`, `matches_filetype`, `matches_bufname`,
  `is_tree_buffer`, …) as JSON. On the affected files you will see
  `matches_filetype=false` but `is_tree_buffer=true`.
- `:ReproDump [path]` — write all captured ClaudeCode notifications as JSON.
- `:ReproClear` — clear the captured-notification buffer.

## Headless / automated reproduction

For a deterministic, CI-style check that drives the real `:ClaudeCodeSend`
command and exits non-zero when the bug is present:

```bash
nvim --headless -u NONE -l scripts/repro_issue_289.lua; echo "exit=$?"
```

`exit=1` ⇒ reproduced (a `lua` buffer whose path contains `neo-tree` is
misrouted into tree extraction while the control buffer sends correctly).
`exit=0` ⇒ fixed.
