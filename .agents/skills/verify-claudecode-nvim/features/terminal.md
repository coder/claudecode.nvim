# Run Claude in a terminal split

The user starts the Claude Code CLI in a terminal split with `:ClaudeCode`, then hides, shows, focuses, and stops it with the same command family. `:ClaudeCodeSendText` types into its prompt, and `:ClaudeCodeSelectModel` starts it with a picked model. The terminal buffer has the filetype `claudecode`, so user autocmds can target it. The `none` provider opens nothing, and `external` starts the CLI outside Neovim.

## Sub-features

- `term-toggle` `:ClaudeCode` starts the terminal in a right split, 30% of the columns wide, in terminal mode. On a visible terminal it hides the window, and on a hidden one it shows the same job again.
- `term-args` words after `:ClaudeCode`, `:ClaudeCodeFocus`, or `:ClaudeCodeOpen` go after `terminal_cmd` (default `claude`), but only when a new terminal starts.
- `term-focus` `:ClaudeCodeFocus` focuses a visible terminal, hides it when it is the current window, and shows and focuses a hidden one. `:ClaudeCodeOpen` shows and focuses, and never hides.
- `term-close` `:ClaudeCodeClose` stops the job and removes the buffer and its window. When the job exits by itself, its window closes (`terminal.auto_close`, default `true`).
- `term-send` `:ClaudeCodeSendText {text}` types `{text}` and Enter into the running terminal and leaves focus where it is. `:ClaudeCodeSendText!` leaves out the Enter. With no terminal it warns `Cannot send text: no Claude terminal is currently running.`
- `term-model` `:ClaudeCodeSelectModel [args]` lists the `models` option under `Select Claude model:` and runs `:ClaudeCode --model <value> [args]` with the pick.
- `term-filetype` the native and snacks terminal buffers have filetype `claudecode`, set once per terminal.
- `term-env` the job gets `CLAUDE_CODE_SSE_PORT` (the plugin's port), `ENABLE_IDE_INTEGRATION=true`, and `FORCE_CODE_TERMINAL=true`.
- `term-providers` under `none`, `:ClaudeCode`, `:ClaudeCodeFocus`, and `:ClaudeCodeOpen` do nothing. Under `external`, `:ClaudeCode` runs `provider_opts.external_terminal_cmd` with `%s` replaced by the command, outside Neovim.

## How to get to it (user POV)

- The user types `:ClaudeCode`, `:ClaudeCodeFocus`, `:ClaudeCodeOpen`, or `:ClaudeCodeSelectModel`, each with optional CLI arguments, or `:ClaudeCodeClose` or `:ClaudeCodeSendText[!] {text}`.
- The user's config has `autocmd FileType claudecode ...`.
- The CLI in the terminal exits.

## Driving it with vcn.sh

Preconditions:

- The harness never runs `claude`, so the terminal runs a shell that prints its arguments. Launch with `C="sh -c 'echo \"ARGS: \$*\"; exec sh' claude"; VCN_SETUP=$(jq -nc --arg c "$C" '{terminal_cmd:$c,terminal:{provider:"native"}}') $V launch -c 'let g:cc_ft = 0 | autocmd FileType claudecode let g:cc_ft += 1' hello.txt`. `$V doctor` is all `ok`.
- Set `T="luaeval(\"require('claudecode.terminal').get_active_terminal_bufnr() or 0\")"` in each shell that reads the terminal text. Before each `:` command or `Ctrl+W` typed in the terminal, leave terminal mode with `$V keys 'Ctrl+\' 'Ctrl+N'` and `$V until 'mode()' n`.

Steps:

- **Start.** Run `$V keys ':ClaudeCode' Enter` and `$V until "mode() . '|' . &buftype . '|' . &filetype" 't|terminal|claudecode'`. `$V expr "winnr('\$') . '|' . winwidth(0) . '|' . g:cc_ft"` prints `2|48|1`, and `$V until "match(getbufline($T, 1, '\$'), '^ARGS: *\$') >= 0" 1` passes. Run `$V capture term-start` and `$V screenshot term-start`.
- **Hide and show.** Save `J=$($V expr 'b:terminal_job_id')`. `:ClaudeCode` gives `$V until "winnr('\$') . '|' . bufname()" '1|hello.txt'`. `:ClaudeCode` again gives `$V until "mode() . '|' . b:terminal_job_id . '|' . g:cc_ft" "t|$J|1"`: the same job, and no second `FileType`.
- **Focus.** Run `$V keys Ctrl+W h` and `$V until 'bufname()' hello.txt`. `:ClaudeCodeFocus` gives `$V until "mode() . '|' . winnr('\$')" 't|2'`. From the terminal window, `:ClaudeCodeFocus` makes `winnr('$')` `1`, and once more gives `t|2`. `:ClaudeCodeOpen` from the terminal window keeps `t|2`.
- **Send text.** From `hello.txt`, run `$V keys ':ClaudeCodeSendText echo PORT=$CLAUDE_CODE_SSE_PORT' Enter`. `$V until "match(getbufline($T, 1, '\$'), '^PORT=$PORT') >= 0" 1` passes, and `$V expr 'bufname()'` still prints `hello.txt`. `:ClaudeCodeSendText! echo BANG` leaves no terminal line that starts with `BANG`.
- **Close.** `:ClaudeCodeClose` gives `$V until "winnr('\$') . '|' . $T" '1|0'`. Then `:ClaudeCodeSendText hi` adds `no Claude terminal is currently running` to `:messages`.
- **Arguments and model.** Run `$V keys ':ClaudeCode --model sonnet' Enter`. `$V until "match(getbufline($T, 1, '\$'), '^ARGS: --model sonnet') >= 0" 1` passes. Leave terminal mode and run `:ClaudeCodeClose`. Run `$V keys ':ClaudeCodeSelectModel' Enter`, then `$V capture term-model-list`: it shows `Select Claude model:` and `2: Claude Opus (Latest, 1M context)`. `$V keys 2 Enter` starts a terminal whose first line is `ARGS: --model opus[1m]`.
- **Exit.** In terminal mode, run `$V keys exit Enter`. `$V until "winnr('\$')" 1` passes.
- **Providers.** On a baseline launch (`none`), `:ClaudeCode`, `:ClaudeCodeFocus`, and `:ClaudeCodeOpen` leave `winnr('$')` at `1`. For `external`, launch with `VCN_SETUP=$(jq -nc --arg c "sh -c 'echo %s > ext.out'" '{terminal:{provider:"external",provider_opts:{external_terminal_cmd:$c}}}') $V launch` and run `$V keys ':ClaudeCode --model haiku' Enter`. `$V until "filereadable('ext.out')" 1` passes, `cat "$WORK/ext.out"` prints `claude --model haiku`, and `winnr('$')` stays `1`.
- **Snacks.** Clone snacks.nvim as in [send-at-mention](./send-at-mention.md), and launch as in Preconditions with `provider:"snacks"` and `--cmd 'set rtp^=<dir>'`. Every step above gives the same result.
- **Proof.** Keep the `term-start` and `term-model-list` captures, and end with `$V record terminal`.

## Gotchas

- Arguments reach only a new terminal. With a terminal open or hidden, `:ClaudeCode --model x` and a `:ClaudeCodeSelectModel` pick just hide or show the old one. Run `:ClaudeCodeClose` first.
- The model list is a blocking prompt, and RPC does not answer while it shows. Read it with `$V capture`, and answer with a number and `Enter`, or with `Escape`, before any `$V expr`.
- Plain `terminal_cmd = "sh"` cannot test arguments: `sh --model opus` exits at once, and its window closes. Use the `ARGS:` shell.
- Under `none`, the `:ClaudeCodeSendText` warning is wider than the screen, so Neovim waits at `Press ENTER` and RPC stops answering. Run `$V capture` and then `$V keys Enter`.
