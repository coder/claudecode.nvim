-- snacks.nvim, present in the reporter's repro. claudecode's terminal provider
-- auto-selects snacks when available; including it keeps the environment faithful
-- even though the crash itself is in the diff/redraw path, not the terminal.
return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  ---@type snacks.Config
  opts = {},
}
