# paste-repro — triage & reproduction for issue #161

**Issue:** [#161](https://github.com/coder/claudecode.nvim/issues/161) — "Pasting text with
Cmd+V in the Claude Code terminal truncates content, while right-click paste works."

## TL;DR verdict

This is **not a claudecode.nvim bug**. It is an upstream **Neovim core** bug in the default
terminal paste path ([neovim/neovim#39110](https://github.com/neovim/neovim/issues/39110)),
fixed by [PR #39152](https://github.com/neovim/neovim/pull/39152) (milestone **0.12.2**) and
backport #39174. The plugin never touches the paste path, so it inherits whatever the running
Neovim build does.

A large bracketed paste into a `:terminal` buffer is streamed through `vim.paste(lines, phase)`
in phases (1→2→…→3). On **affected builds**, each streamed phase is independently wrapped in its
own `ESC[200~ … ESC[201~` bracketed-paste markers, so one logical paste reaches the inner program
(Claude) as **N separate paste events**. Claude renders N `[Pasted text #k]` placeholders with
phase-boundary characters leaking between them — which the user perceives as truncation.

| Neovim build                 | bracketed-paste segments seen by inner PTY | verdict         |
| ---------------------------- | ------------------------------------------ | --------------- |
| 0.11.5 (reporter's version)  | **6**                                      | 🐛 fragmented   |
| 0.11.6 (commenter's version) | **6**                                      | 🐛 fragmented   |
| 0.12.2 (fix present)         | **1**                                      | ✅ single paste |
| 0.11.6 + workaround          | **1**                                      | ✅ single paste |

(Counts are for a 120-line / ~6 KB payload; the number of segments scales with paste size.)

## Why it is size/timing dependent

The fragmentation is driven by **TUI input read chunking** (~1 KB reads). A paste small enough to
land in a single read arrives as one non-streamed `phase == -1` call → one segment → no bug.
A larger paste spans multiple reads → streamed phases 1/2/…/3 → on an affected build, one segment
per phase. This is why short pastes look fine and large pastes "truncate", and why there is no
fixed line threshold.

## Root-cause chain (verified)

1. Emulator (WezTerm/Ghostty/iTerm2) wraps the clipboard in `ESC[200~ … ESC[201~` and writes it
   to Neovim's PTY as one logical paste.
2. Neovim's TUI streams it through `vim.paste(lines, phase)` — `runtime/lua/vim/_core/editor.lua`
   (historically `runtime/lua/vim/_editor.lua`). For a terminal buffer the handler runs
   `nvim_put(lines, 'c', false, true)` **once per phase** (editor.lua:185-186).
3. Each `nvim_put` → C `do_put` (`register.c`) → `terminal_paste` (`terminal.c`), which wraps the
   write in bracketed-paste markers **iff** the inner program enabled DECSET 2004.
4. **The defect:** before #39152, `terminal_paste` emitted start/end markers _unconditionally on
   every call_, so N phases ⇒ N bracketed segments. The fix added a `streamed_paste` flag (managed
   across phases by `nvim_paste` in `api/vim.c`) so the whole stream gets exactly one marker pair.
   The fix is at the **C layer**; the Lua `vim.paste` in 0.12.2 still does a per-phase `nvim_put`.

`claudecode.nvim` does **not** override `vim.paste`, set paste keymaps, or call
`nvim_chan_send`/`nvim_paste` (native.lua uses plain `vim.fn.termopen`; snacks.lua delegates to
`Snacks.terminal.open`). It neither causes nor currently mitigates the bug.

### Why right-click may differ from Cmd+V (unverified)

Plausibly, right-click paste in some emulators injects clipboard bytes **directly into the inner
PTY**, bypassing Neovim's `vim.paste` streaming entirely, so it arrives as one clean bracketed
paste. Cmd+V is intercepted by the TUI and routed through the streamed phases. This is
emulator-/keybinding-dependent and was not confirmed in a controlled test.

## How this fixture proves it

`claude` requires auth and hides its paste handling, so this fixture replaces it with
[`observer.py`](./observer.py): a tiny program that enables bracketed paste (DECSET 2004) and logs
exactly how many `ESC[200~`/`ESC[201~` segments the inner PTY receives. **Segment count is the
signal** (`start_markers`/`end_markers` in the log's `TOTAL` line): `>1` = bug, `1` = correct.
The observer is wired in as `terminal_cmd`, so pastes flow through the _real_ plugin terminal path.

## Reproduce it

The bug only appears on an affected Neovim. Install one with mise:

```bash
mise install neovim@0.11.6      # affected (also 0.11.5, 0.12.1)
```

### A. Automated (agent-tty) — deterministic, no manual steps

From the repo root:

```bash
NVIM_BIN="$HOME/.local/share/mise/installs/neovim/0.11.6/bin/nvim" \
  fixtures/paste-repro/agent-repro.sh
```

Expected on 0.11.6:

```
  default            TOTAL ... start_markers=6 end_markers=6  => BUG (fragmented)
  with-workaround    TOTAL ... start_markers=1 end_markers=1  => OK (single paste)
```

Re-run with a 0.12.2 `NVIM_BIN` and both rows report `OK` — demonstrating the version fix.
The script drives a real Neovim TUI in an isolated agent-tty session, auto-opens the plugin's
Claude terminal (`PASTE_REPRO_AUTOOPEN=1`), pastes via bracketed paste, and reports segments.

### B. Manual (interactive)

```bash
source fixtures/nvim-aliases.sh
PATH="$HOME/.local/share/mise/installs/neovim/0.11.6/bin:$PATH" vv paste-repro
```

Then inside Neovim:

1. `<leader>ac` opens the Claude terminal (running `observer.py`); you'll see `OBSERVER READY`.
2. Copy 100+ lines to the system clipboard and paste with **Cmd+V** (bracketed paste).
3. Inspect the observer log (path shown by `<leader>al`, default
   `:echo stdpath('cache')`/`claudecode-paste-observer.log`): a `start_markers` > 1 in the `TOTAL`
   line is the bug. Set `APPLY_PASTE_FIX=1` before launching to verify the workaround collapses it
   to 1.

### C. Pure-Neovim isolation (no plugin) — proves it's core, not the plugin

```bash
NVIM=$HOME/.local/share/mise/installs/neovim/0.11.6/bin/nvim
$NVIM --clean -c "terminal python3 $PWD/fixtures/paste-repro/observer.py /tmp/obs.log" -c startinsert
# paste 100+ lines, then: grep TOTAL /tmp/obs.log   -> start_markers=6 on 0.11.6, =1 on 0.12.2
```

## The workaround (and its edge cases)

The community workaround (huiyu + kyleawayan, in the issue thread) overrides `vim.paste` for
terminal buffers to coalesce streamed phases into a single `phase == -1` replay (toggle in this
fixture with `APPLY_PASTE_FIX=1`):

- Coalescing to `phase == -1` → one `nvim_put` → one bracketed segment → one `[Pasted text]`.
- kyleawayan's refinement re-glues the mid-line chunk seam
  (`chunks[#chunks] = chunks[#chunks] .. lines[1]`); without it, every chunk boundary injects a
  spurious newline (because `lines` is a `readfile()`-style split with delimiters dropped).
- **Residual edge case** (flagged for the fix phase, not verified here): a chunk boundary landing
  exactly on a source newline could drop a legitimate newline. Worth a targeted test before
  shipping.

## Recommendation

- **Real fix:** upgrade Neovim to **0.12.2+**.
- **Mitigation for users on 0.11.x / 0.12.1:** ship the coalescing `vim.paste` override behind a
  config flag (e.g. `terminal.fix_streamed_paste`), scoped to `buftype == 'terminal'`.

## Files

- `init.lua` — fixture config (native provider; `terminal_cmd` → observer; `APPLY_PASTE_FIX`,
  `PASTE_REPRO_AUTOOPEN`, `PASTE_OBSERVER_LOG` env toggles).
- `observer.py` — bracketed-paste segment counter (the measurement instrument).
- `agent-repro.sh` — self-contained automated reproduction via agent-tty.
