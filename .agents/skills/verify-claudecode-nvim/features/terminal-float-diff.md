# Review a diff while the Claude terminal is a Snacks float

With `terminal.provider = "snacks"` and `snacks_win_opts.position = "float"`, Claude's terminal is a floating window over the editor. A float cannot make room for a diff, so the plugin hides it when a diff opens in the float's tab. It stays hidden when the diff closes, and `:ClaudeCodeFocus` brings it back. A diff in its own tab (`open_in_new_tab`, or the new tab a split diff opens in when its tab already shows a diff) is the exception: when it closes, the plugin shows the terminal again if a window of it was visible in any tab when the diff opened, and none is visible then. That can show the float over another diff that is still open. The diff window has focus, and no floating window covers either diff window. With `diff_opts.keep_terminal_focus = true`, the float stays on screen with focus and covers the diff.

## Sub-features

- `float-hide` hides the float, and its backdrop, when a split or unified diff opens, and leaves the diff window focused in Normal mode.
- `float-stays-hidden` leaves the float hidden after `close_tab`, so nothing covers the user's editor window.
- `float-keep-focus` leaves the float on screen, with focus, when `diff_opts.keep_terminal_focus = true`.
- `float-reload` keeps a float hidden that the user showed through the Snacks instance and hid with Snacks' `q`, after the plugin reloaded (`:Lazy reload`) and a diff hid the float. `close_tab` brings nothing back.

## How to get to it (user POV)

- The user runs `:ClaudeCodeFocus` (or `:ClaudeCode`) to open the Claude terminal as a float, and types in it.
- Claude calls `openDiff` while the float has focus.
- Claude calls `close_tab` after the user accepted or rejected.

## Driving it with vcn.sh

Preconditions:

- A snacks.nvim clone, for example `git clone --depth 1 https://github.com/folke/snacks.nvim "$XUM_SCRATCH_DIR/snacks.nvim"`. Record `git -C <clone> rev-parse HEAD` in the report.
- A fresh launch with the clone on the runtimepath and the float config. `scripts/fake-terminal.sh` is the terminal command, so no `claude` CLI starts:

  ```bash
  V=.agents/skills/verify-claudecode-nvim/scripts/vcn.sh
  export VCN_RTP="$XUM_SCRATCH_DIR/snacks.nvim"
  export VCN_SETUP="$(jq -nc --arg c "$PWD/.agents/skills/verify-claudecode-nvim/scripts/fake-terminal.sh" \
    '{terminal_cmd:$c, terminal:{provider:"snacks", snacks_win_opts:{position:"float",width:0.9,height:0.9}}, diff_opts:{layout:"vertical", keep_terminal_focus:false}}')"
  $V launch
  ```

  Set `layout` to `"unified"` or `keep_terminal_focus` to `true` for the other cases.

Steps:

- **Open the float.** Run `$V keys ':ClaudeCodeFocus' Enter`. `$V capture float-1-terminal` shows the banner line from `fake-terminal.sh` in the float. The mode is `t` and the current window is the float.
- **Open the diff.** Run `$V tool f1 openDiff "$(jq -nc --arg p "$WORK/hello.txt" '{old_file_path:$p,new_file_path:$p,new_file_contents:"alpha\nBETA\ngamma\n",tab_name:"✻ [Claude Code] hello.txt (f1) ⧉"}')"`. With `keep_terminal_focus = false`, `$V until "bufname() =~# '(proposed)$'" 1` passes (`(unified diff)$` for the unified layout), `$V screenshot float-2-open` shows both diff windows with no float over them, and the observer below reports `visible_floats` 0.
- **Observe.** `$V expr "luaeval('dofile(\"$PWD/.agents/skills/verify-claudecode-nvim/scripts/observe-windows.lua\")')"` prints one JSON object: `mode`, `current_buf`, `current_is_float`, each window's rectangle, `visible_floats`, `visible_terminal_floats`, and `covered` (per diff window, the cells a visible float covers). A `covered_cells` above 0 means a float hides part of the diff.
- **Close.** Run `$V tool c1 close_tab "$(jq -nc '{tab_name:"✻ [Claude Code] hello.txt (f1) ⧉"}')"`. The answer is `TAB_CLOSED`, and `visible_floats` stays 0 with the float hidden. `$V keys ':ClaudeCodeFocus' Enter` brings it back.
- **Proof.** On a fresh launch with the config above, run `.agents/skills/verify-claudecode-nvim/scripts/journey-snacks-float-diff.sh`. It reads the layout and `keep_terminal_focus` from the running plugin, drives the steps, and prints `PASS snacks-float-diff <layout> <nokeep|keep>` or `FAIL: <reason>`. It writes `snacks-float-<layout>-<focus>-1-terminal`, `-2-open` and `-3-closed` screen captures, PNGs and window-state JSON, plus a WebM, to `$OUT`.

- **Reload proof.** On a fresh launch with the same config (`layout` `"vertical"` or `"unified"`, `keep_terminal_focus` false), run `.agents/skills/verify-claudecode-nvim/scripts/journey-snacks-float-reload.sh`. It opens the float, clears every `claudecode` module and runs setup again with the running config, calls `openDiff`, shows the float with the Snacks instance's `toggle`, hides it with `q`, calls `close_tab`, and prints `PASS snacks-float-reload` or `FAIL: <reason>`. It writes `snacks-float-reload-*` captures, PNGs and window-state JSON to `$OUT`.

## Gotchas

- The `provider = "none"` default has no terminal at all. Without `VCN_RTP`, `terminal.provider = "snacks"` falls back to the native provider and no float exists.
- Snacks draws a backdrop as a second, full-screen floating window with no name. It counts in `visible_floats` and must be hidden together with the terminal float.
- The float is hidden with `hide`, so its window still exists. Read `hide` in the window config, not just the window list. `observe-windows.lua` does.
- The journey leaves the real `claude` CLI alone: `fake-terminal.sh` only prints a line and sleeps, and the scripted client plays Claude.
- A second diff in the same tab opens in a new tab (split layouts). That tab shows the terminal as a split, or no terminal with `hide_terminal_in_new_tab`. With two diffs the float stays hidden after both close, because no window of the terminal was visible when the second diff opened. A third diff can bring the float back: with the default `hide_terminal_in_new_tab`, it opens while the second diff's tab shows the terminal. When the second diff closes first, the third diff's close shows the terminal again, over the first diff. When the third diff closes first, the float stays hidden. Check `visible_terminal_floats` and `covered` in the first tab after each diff closes. With three diffs, expect the float back over the first diff only when the second diff closes before the third.
