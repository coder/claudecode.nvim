-- AFFECTED FILE for issue #289.
--
-- This is an utterly ordinary Lua file. Its FILETYPE is `lua`. The ONLY reason
-- ClaudeCodeSend misbehaves here is that its PATH contains the substring
-- "neo-tree" (this file is named `_neo-tree_.lua`), which trips the
-- `string.match(current_bufname, "neo%-tree")` false positive.
--
-- Visually select a few of these lines and press <leader>as (or run
-- :'<,'>ClaudeCodeSend) -> you get a TreeAdd error and nothing is sent.

return {
  "nvim-neo-tree/neo-tree.nvim",
  branch = "v3.x",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "nvim-tree/nvim-web-devicons",
    "MunifTanjim/nui.nvim",
  },
  config = function()
    require("neo-tree").setup({
      close_if_last_window = true,
      filesystem = {
        follow_current_file = { enabled = true },
      },
    })
  end,
}
