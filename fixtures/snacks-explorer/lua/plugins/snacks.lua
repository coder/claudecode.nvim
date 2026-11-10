-- Snacks Explorer (LazyVim's default file explorer) reproduction fixture.
-- The explorer sidebar is what issue #236 reports the diff incorrectly opening into.
return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  ---@type snacks.Config
  opts = {
    explorer = { enabled = true },
    picker = {
      enabled = true,
      sources = {
        explorer = {
          -- Match LazyVim defaults: left sidebar, auto-close disabled so it
          -- stays open like a tree explorer.
          layout = { preset = "sidebar", preview = false },
        },
      },
    },
  },
  keys = {
    {
      "<leader>e",
      function()
        Snacks.explorer()
      end,
      desc = "Snacks Explorer",
    },
  },
}
