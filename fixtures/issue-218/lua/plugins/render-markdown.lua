-- render-markdown.nvim — the plugin the reporter fingered. Removing it makes the
-- crash disappear (verified). Note: it does NOT render diff-mode windows by
-- default; merely being *attached* to the markdown proposed buffer (its
-- buffer-local autocmds + treesitter) is enough to make the teardown's
-- `:tabclose` crash Neovim.
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
