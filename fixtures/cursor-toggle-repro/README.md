# cursor-toggle-repro — triage & reproduction for #240 / #183

**Issues:**
[#240](https://github.com/coder/claudecode.nvim/issues/240) — "When re-opening the
Claude side panel, the cursor is one line higher than it should be" (vertical split).
[#183](https://github.com/coder/claudecode.nvim/issues/183) — "Input cursor in
floating mode moves upwards every time I toggle" (float). **Same root cause.**

## TL;DR verdict

With the **Snacks** terminal provider (LazyVim's default), hiding and re-showing the
Claude window leaves the terminal cursor **one row above** Claude's `❯` input prompt,
so typed text lands on the wrong line and the prompt box visibly corrupts. The
plugin's **native** provider does **not** show this.

The popular community fixes (RasmusN's fork, mwojick's gist) attribute the bug to a
**`SIGWINCH`/pty resize** when Snacks destroys the window. **That is not what happens
here** — instrumenting the inner PTY shows **zero `SIGWINCH`** on toggle. The real
chain is:

1. Snacks hides the panel by **closing the window** (`nvim_win_close(win, true)`) and
   re-shows it by **recreating** it — for both splits and floats. Chain in
   `snacks.nvim/lua/snacks/win.lua`: `Win:hide` (619) → `Win:close({buf=false})` (542,
   `nvim_win_close` at 562) → `Win:show` (819) → `open_win`. Snacks has **no
   hide-without-close** option. The native provider also closes/reopens, but does not
   trigger the drift.
2. On hide Neovim sends **focus-out** (`ESC[O` / `CSI O`) and on show **focus-in**
   (`ESC[I` / `CSI I`) to the child, because Claude enables focus reporting
   (DECSET `?1004`). (Confirmed in Neovim source: `terminal_focus()` →
   `vterm_state_focus_in/out()` → bytes to the child via `term_output_callback`.)
3. Claude Code (built on **Ink**, which redraws **relative** to the cursor) re-renders
   its TUI on focus-in. After the window was destroyed/recreated, its cursor anchor is
   off by one, so the relative redraw lands one row too high — and keeps climbing.

Two facts pin the layers:

- **Focus change alone does not drift.** Moving Neovim focus editor↔terminal _without_
  hiding the window never drifts. The window destroy+recreate is a required co-factor.
- **Absolute-positioning programs do not drift; only Claude does.** _Measured_
  (`box-delta-check.sh`): a synthetic TUI that redraws with absolute cursor moves
  (`CSI row;col H`) keeps its cursor on its `>` prompt row (cursorRow=35) across every
  toggle — zero drift — under the identical Snacks float churn that moves real Claude by
  one row. This rules out a Neovim PTY/window coordinate bug and pins the drift to
  Claude's **cursor-relative Ink repaint**. Consistent with the community report that
  **downgrading Claude to `2.0.76` makes it disappear**. So this is substantially a
  **Claude-CLI-side** rendering behavior that Snacks' window churn exposes; the plugin
  can only _work around_ it.
- **"Destroy/recreate" is not the _sole_ discriminator — _how_ Snacks recreates is.**
  The native provider _also_ closes the window on hide (`nvim_win_close`,
  `native.lua:193`) and creates a _new_ window on show (`vsplit` + `nvim_win_set_buf`,
  `native.lua:227-232`) reusing the same terminal buffer — yet it does **not** drift.
  Snacks re-shows a float via `nvim_open_win` (`win.lua:733`), which is what resets the
  cursor/scroll anchor. The snacks-only A/B (close+recreate → delta 1; config-hide →
  delta 0) isolates the recreate within the snacks float; native shows a _different_
  recreate path is immune. (RasmusN's fork also `nvim_win_set_cursor`-scrolls to bottom
  and defers `startinsert`, hinting the new float window's scroll/cursor view on re-show
  is the proximate anchor shift.)

| layer                    | role                                                                                             |
| ------------------------ | ------------------------------------------------------------------------------------------------ |
| Claude CLI ≥ 2.1.x (Ink) | re-renders relative-to-cursor on focus-in → the actual climb; older 2.0.76 did not               |
| Snacks provider          | hide=close-window, show=recreate-window → disturbs the cursor anchor that Claude redraws against |
| Neovim                   | forwards focus-out/in to the child on window hide/show (no resize)                               |

Each link in this chain was re-checked against primary sources (the Neovim 0.12.2
binary's terminal/focus source, the pinned snacks.nvim source, and api.txt) by an
independent adversarial pass; all held. The one thing the community fixes get wrong is
the _cause_ (they say `SIGWINCH`); their _mechanism_ (stop destroying the window) is
right anyway, because it preserves the cursor anchor.

## Reproduce it

### A. Automated (agent-tty)

```bash
fixtures/cursor-toggle-repro/agent-repro.sh
```

- **PART A (no auth):** runs `box.py` (a synthetic TUI that enables focus reporting and
  logs every byte + `SIGWINCH`) as the terminal command and toggles the window. Expected:
  `SIGWINCH events on toggle: 0`, with `FOCUS_IN`/`FOCUS_OUT` on every cycle — proving
  the trigger is focus churn, not a resize.
- **PART B (needs a logged-in `claude`):** runs the real Claude CLI under both providers
  and prints the cursor-vs-prompt `delta` after each toggle:

  ```
  -- provider=snacks --
     baseline:        cursorRow=9 promptRow=9 delta=0
     after toggle 1:  cursorRow=8 promptRow=9 delta=1   <- BUG (cursor one row above ❯)
  -- provider=native --
     baseline:        cursorRow=9 promptRow=9 delta=0
     after toggle 1:  cursorRow=9 promptRow=9 delta=0   <- fine
  ```

#### #183 float, measured this session (Claude 2.1.168, nvim 0.12.2, current `main`)

```text
$ ./float-repro.sh                # the bug
== provider=snacks (float) ==
   baseline:        delta=0
   after toggle 1..5: delta=1     <- cursor one row ABOVE ❯ on every toggle
   final: typed "ZZZQ" rendered as "──ZZZQ" ON THE BOX TOP BORDER (row 9), ❯ on row 10
== provider=native (float) ==
   baseline..toggle 5: delta=0    <- fine; "ZZZQ" rendered as "❯ ZZZQ"

$ ./float-fix-probe.sh            # the candidate fix (config-hide)
== provider=snacks (float) + CONFIG-HIDE ==
   baseline..toggle 5: delta=0    <- FIXED; "ZZZQ" rendered as "❯ ZZZQ"

$ ./box-float-check.sh            # instrument: not a resize
   SIGWINCH events on toggle: 0   FOCUS_IN: 4   FOCUS_OUT: 4   (4 cycles)

$ ./box-delta-check.sh            # control: absolute-positioning TUI is immune
== box.py (absolute CSI row;col H) under snacks float ==
   baseline..toggle 3: cursorRow=35 (stable) — cursor stays ON its "> " prompt row, NO drift
```

The snacks-vs-config-hide A/B holds the focus flow identical (move to editor → hide →
re-show+focus); the only difference is whether the window is **destroyed** or **kept**, so
the destroy/recreate is the trigger. `box-float-check.sh` confirms the toggle is **not** a
pty resize. (Note: in this automated flow the snacks/float drift stabilizes at delta=1 —
each toggle re-introduces a 1-row error rather than climbing unbounded; the user-visible
symptom, "typed text lands on the wrong line after a toggle," is the same.)

### B. Manual (interactive)

```bash
cd fixtures && NVIM_APPNAME=cursor-toggle-repro XDG_CONFIG_HOME="$PWD" \
  mise exec -- nvim cursor-toggle-repro/sample.txt
```

1. `<leader>ac` opens the Claude terminal (Snacks split).
2. `<C-\><C-n>` then `<C-w>h` to the editor; `<leader>ac` to hide, `<leader>ac` to show.
3. The `❯` prompt is drawn where it was, but the cursor (and anything you type) is now one
   row higher. Toggle again to see it worsen / corrupt the box.

Env knobs (see `init.lua`): `CURSOR_REPRO_PROVIDER` (`snacks`|`native`),
`CURSOR_REPRO_POSITION` (`right`|`float` = #183), `CURSOR_REPRO_CMD` (run `box.py`
instead of `claude`), `CURSOR_REPRO_BORDER`. `:ReproCursorInfo` / `:ReproWinDiag` dump
geometry to `$CURSOR_REPRO_LOG`.

## Fixes & workarounds

> Validated here = measured to keep `delta=0` across toggles with real Claude.

1. **Config-hide (validated for floats — fixes #183).** Hide/show via
   `nvim_win_set_config(win, {hide=true/false})` instead of closing+recreating the
   window. Keeping the window object alive preserves the grid + cursor anchor, so Claude's
   focus-in redraw stays aligned. This is what RasmusN's fork and mwojick's "parking
   float" do (their _stated_ reason — avoiding `SIGWINCH` — is wrong, but the fix works for
   a different reason: it preserves the anchor). **Caveat:** `{hide=true}` does **not**
   visually hide a _non-floating split_ in Neovim 0.12.2 (the window stays visible), so this
   path is a clean fix for **floats only**. Re-confirmed this session on Claude 2.1.168 via
   `float-fix-probe.sh` (delta stays 0 across 5 toggles; typed text lands after `❯`).
   **Plugin-integration caveat:** a config-hidden window is still `nvim_win_is_valid()==true`,
   so the snacks provider's `simple_toggle`/`focus_toggle` visibility checks
   (`terminal:win_valid()`) would treat it as still-visible. A real plugin fix must gate on
   `nvim_win_get_config(win).hide` (what the fixture's `:ReproConfigHideToggle` does) or track
   hidden state, and must manage the window directly rather than via `terminal:toggle()`.

2. **Use the native provider (workaround for #240 split users, today).**
   `terminal = { provider = "native" }` — does not drift. Loses Snacks' float/UI niceties.

3. **Downgrade Claude CLI to `2.0.76` (workaround).** Confirms the bug is in Claude's
   newer focus-driven redraw; not a long-term fix.

4. **Upstream (the real fix):** Claude Code's focus-in re-render should not depend on a
   cursor anchor that can move; this is the layer that regressed between 2.0.76 and 2.1.x.

**What did NOT work:** `start_insert=false` + scroll-to-bottom + deferred `startinsert`
(RasmusN's split-side change) — still `delta=1` here. Setting `border="none"` (matching the
native row count) — still `delta=1`. So neither the insert timing nor the 1-row height
difference is the cause.

## Files

- `init.lua` — fixture config (Snacks provider; loads the local plugin + snacks via rtp).
  Also defines `:ReproConfigHideToggle` / `<leader>ah`, the candidate-fix probe that
  hides the float via `nvim_win_set_config{hide=…}` instead of closing the window.
- `box.py` — synthetic TUI / instrument: enables focus reporting, logs input bytes + SIGWINCH.
- `sample.txt` — filler content for the "main editor" window.
- `agent-repro.sh` — self-contained automated reproduction for the **split** (#240):
  PART A (box.py, no-auth) + PART B (real Claude, snacks vs native).
- `float-repro.sh` — **#183-specific** automated reproduction: Snacks `position="float"`,
  real Claude, hides+re-shows N times and prints the cursor-vs-`❯` delta. snacks→delta 1,
  native→delta 0; ends by typing `ZZZQ` to show where input lands.
- `float-fix-probe.sh` — validates the candidate fix: same float harness but toggles via
  `<leader>ah` (config-hide). Measures whether delta stays 0.
- `box-float-check.sh` — instrument refresh on the float: counts SIGWINCH vs focus
  events across snacks close+recreate toggles (proves 0 SIGWINCH, focus churn present).
