# Fixture: issue #232 — terminal jumps to the bottom / re-enters insert mode on re-focus

> [FEATURE] Terminal window should restore scroll position when switching back
> from editor window — https://github.com/coder/claudecode.nvim/issues/232
>
> Duplicate of #145; an implementation already exists as **PR #233**
> (`terminal.auto_insert`).

## Symptom

With the **Snacks** terminal provider (the default when `snacks.nvim` is
installed), reading Claude's output in Normal mode and then switching focus back
into the terminal window (e.g. `<C-w>l` / `<C-l>`) throws you back into
terminal-mode at the bottom prompt, discarding your scroll/reading position.

## Root cause

`build_opts` in `lua/claudecode/terminal/snacks.lua` passes Snacks
`auto_insert = focus`. Snacks' `auto_insert` registers a **buffer-local
`BufEnter` autocmd that runs `startinsert` on every entry** into the terminal
buffer, so re-focusing the window forces terminal-mode and snaps to the prompt.
The **native** provider registers no such autocmd, so it does NOT exhibit this
on plain window navigation (it only force-inserts on `:ClaudeCodeFocus`/toggle).

`snacks_win_opts` cannot fix this from user config: it is merged only into the
Snacks `win` table, whereas `auto_insert`/`start_insert` are top-level
`snacks.terminal.Opts` fields (this is exactly what the #145 reporter tried).

## Run it

```sh
source fixtures/nvim-aliases.sh

# Reproduce (Snacks, default):
CLAUDECODE_PROVIDER=snacks vv issue-232

# Baseline (native — does NOT reproduce):
CLAUDECODE_PROVIDER=native vv issue-232
```

The fixture uses `fake-claude.sh` (200 lines of output + a live `cat` prompt) in
place of the real Claude CLI, so no auth/network is needed.

### Manual steps (matches the issue report)

1. Press `<leader>r` (or `:Repro`) to lay out: sample file (left) + Claude
   terminal (right, focused).
2. In the terminal press `<C-\><C-n>` to enter Normal mode, then `gg` to scroll
   to the top (you should see `claude output line 001`).
3. Press `<C-h>` to jump to the editor window.
4. Press `<C-l>` to jump back to the terminal.

Every window's statusline shows `MODE=%{mode()}` so you can see the mode flip.

- **Snacks (bug):** after step 4 the statusline shows `MODE=t`, `-- TERMINAL --`
  appears, and the view jumps to `claude output line 200` / the `>` prompt.
- **Native (baseline):** after step 4 the statusline stays `MODE=n` and the view
  stays at `claude output line 001`.

## Deterministic / headless check

`scripts/repro_issue_232.lua` asserts the mechanism (the `BufEnter`→`startinsert`
autocmd) without a UI:

```sh
CLAUDECODE_PROVIDER=snacks                          nvim --headless -u NONE -l scripts/repro_issue_232.lua  # exit 1 (reproduced)
CLAUDECODE_PROVIDER=native                          nvim --headless -u NONE -l scripts/repro_issue_232.lua  # exit 0 (baseline)
CLAUDECODE_PROVIDER=snacks CLAUDECODE_AUTO_INSERT=false nvim --headless -u NONE -l scripts/repro_issue_232.lua  # exit 0 (fixed by PR #233)
```

(The visible mode flip needs an attached UI; in headless `-l` mode `startinsert`
is deferred and never applied, so the script keys its verdict off the autocmd
probe, not `mode()`.)

## Workarounds available today (before PR #233 lands)

- Use `terminal = { provider = "native" }` if you rely on `<C-w>l`-style window
  navigation (preserves scroll/Normal mode on re-focus).
- Or copy the snacks provider into a custom provider and drop the `startinsert`
  / `auto_insert` calls (maintainer's suggestion on #145).
