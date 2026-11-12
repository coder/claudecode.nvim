-- render-markdown.nvim — the plugin the reporter fingered. Removing it made the
-- crash disappear when the report was investigated. Note: it does NOT render
-- diff-mode windows by default; merely being *attached* to the markdown proposed
-- buffer (its buffer-local autocmds + treesitter) was enough to make the
-- teardown's `:tabclose` crash Neovim on a build that crashed.
--
-- Mirrors the reporter's spec (deps on nvim-treesitter + web-devicons, default
-- opts). Neovim 0.11+ bundles the markdown/markdown_inline treesitter parsers, so
-- render-markdown attaches even without nvim-treesitter installing anything.
-- Loaded eagerly so it is attached before any diff opens.
return {
  "MeanderingProgrammer/render-markdown.nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "nvim-tree/nvim-web-devicons",
  },
  lazy = false,
  ---@type render.md.UserConfig
  opts = {},
}
