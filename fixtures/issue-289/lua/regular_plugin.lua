-- CONTROL FILE for issue #289.
--
-- Identical in spirit to `_neo-tree_.lua`, but its path contains NONE of the
-- magic substrings (no "neo-tree", "NvimTree", or "minifiles://"). Visually
-- selecting lines here and pressing <leader>as works correctly: the selection
-- is sent (or queued) with no TreeAdd error.

return {
  "some-author/some-plugin.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("some-plugin").setup({
      enabled = true,
      option_one = "value",
      option_two = 42,
    })
  end,
}
