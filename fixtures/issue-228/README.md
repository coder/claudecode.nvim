# Issue #228 — `focus_after_send` with `provider = "none"` / `"external"`

> Source: https://github.com/coder/claudecode.nvim/issues/228

## Background

`focus_after_send = true` focuses the **in-editor** Claude terminal after a send. It
routes through `terminal.open()`, which dispatches to the configured provider. The
`none` provider (`lua/claudecode/terminal/none.lua`) is a no-op by design, and the
`external` provider cannot move focus to an already-running external terminal. So for
those providers `focus_after_send` could never do anything — and it did so **silently**,
with no warning and no documentation of the limitation.

## The fix (this change set)

`focus_after_send` still cannot focus a Claude session running outside Neovim (it
can't — Claude isn't in a Neovim window). Instead:

- **(c)** A one-time warning is emitted at `setup()` when `focus_after_send = true` and
  `terminal.provider` is `"none"` or `"external"`, pointing users at the hook below.
- **(b)** A `User ClaudeCodeSendComplete` autocmd fires on every connected send,
  carrying `data = { file_path, start_line, end_line, context }`, so external-terminal
  users can run their own focus logic:

  ```lua
  vim.api.nvim_create_autocmd("User", {
    pattern = "ClaudeCodeSendComplete",
    callback = function()
      if vim.env.TMUX then
        vim.fn.system({ "tmux", "select-pane", "-t", "{last}" }) -- use your own target
      end
    end,
  })
  ```

## Gate (deterministic, headless, no Claude CLI required)

```sh
# from the repo root
bash fixtures/issue-228/run.sh
#   or: nvim -u NONE -l fixtures/issue-228/repro.lua
```

Expected output ends with:

```
PASS issue #228 fix verified: warning fires for none/external, ClaudeCodeSendComplete fires on send.
```

The harness uses the **real** plugin and the **real** `none` provider, runs four
provider/flag scenarios plus a real `User ClaudeCodeSendComplete` autocmd, and asserts:

| provider       | focus_after_send | #228 warning | focus effect    | event fires |
| -------------- | ---------------- | ------------ | --------------- | ----------- |
| `none`         | `true`           | **1**        | none (no-op)    | yes         |
| `none`         | `false`          | 0            | none (no-op)    | yes         |
| custom (table) | `true`           | 0            | **focus fires** | yes         |
| custom (table) | `false`          | 0            | show, no focus  | yes         |

The `none` rows confirm the limitation is unchanged (no terminal is ever created), but
it is no longer silent (a warning fires) and the `ClaudeCodeSendComplete` event lets the
user focus their own terminal. The custom-provider rows confirm focusable providers are
unaffected and never warn.

## Live confirmation (agent-tty / TUI)

`live.lua` is a minimal fixture (provider `none`, connection stubbed) that exercises the
real `:ClaudeCodeSend` path in a running Neovim and hooks the new event:

```sh
nvim -u fixtures/issue-228/live.lua fixtures/issue-228/sample.txt
# then visually select lines and run  :'<,'>ClaudeCodeSend   (the real path), or
#      run  :Issue228Probe                                   (before/after report)
# -> a "ClaudeCodeSendComplete fired" message appears; :messages also shows the
#    one-time setup warning. focus_after_send itself stays inert for "none".
```
