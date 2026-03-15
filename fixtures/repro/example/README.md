# claudecode.nvim repro workspace

This directory is copied into a temp workspace when you run `repro`.

## Quick start

From the repo root:

```sh
source fixtures/nvim-aliases.sh
repro
```

That will:

- create `/tmp/claudecode.nvim-repro` (reset on every run; use `repro --keep` to reuse)
- open Neovim with the **minimal** `fixtures/repro` config
- open `a.txt` so your current window is non-empty

## Iterating on the config

The Neovim config lives at `fixtures/repro/init.lua`.

- Edit it from another terminal:

  ```sh
  vve repro
  ```

  Then restart the running `repro` Neovim instance to pick up changes.

- Or edit it from inside the running `repro` session:

  ```vim
  :ReproEditConfig
  ```

> Note: config changes generally require restarting Neovim (this fixture avoids a plugin manager / hot-reload).

## Example flow (sanity check)

A basic end-to-end diff flow you can use to sanity-check the environment:

1. Start Claude:

   - press `<leader>ac` (starts the server if needed, then opens the terminal), **or**
   - run `:ClaudeCodeStart` then `:ClaudeCode`

2. Ask Claude to edit `b.txt` (do not open it in a window first)
3. Accept the diff with `:w` (or `<leader>aa`)
4. Confirm you didn’t get any extra leftover windows: `:echo winnr('$')`

## Notes

- This fixture uses the **native** terminal provider to avoid depending on external plugins.
- To tweak the config, edit `fixtures/repro/init.lua` (or run `vve repro`).
