-- snacks.nvim is the default terminal backend for claudecode.nvim ("auto"
-- prefers it when installed). Its terminal is what re-enters insert mode on
-- focus (auto_insert), which is the behavior issue #232 is about.
return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  ---@type snacks.Config
  opts = {
    -- Nothing special; we only need Snacks.terminal available.
  },
}
