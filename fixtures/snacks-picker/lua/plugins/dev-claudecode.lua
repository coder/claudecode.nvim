-- Development configuration for claudecode.nvim with the snacks.nvim picker.
-- Loads the local plugin checkout (resolved in lua/config/lazy.lua) via `dir`
-- so it works from a normal checkout or a git worktree.
return {
  "coder/claudecode.nvim",
  dir = vim.g.claudecode_dev_dir,
  dependencies = { "folke/snacks.nvim" },
  keys = {
    { "<leader>a", nil, desc = "AI/Claude Code" },
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>aS", "<cmd>ClaudeCodeStart<cr>", desc = "Start Claude Server" },
    { "<leader>aQ", "<cmd>ClaudeCodeStop<cr>", desc = "Stop Claude Server" },
    -- Built-in command path: focus the picker LIST window, then run this.
    { "<leader>at", "<cmd>ClaudeCodeTreeAdd<cr>", desc = "Tree/Picker Add" },
  },
  ---@type PartialClaudeCodeConfig
  opts = {
    -- Keep behavior predictable for reproduction; start the server explicitly.
    log_level = "debug",
  },
}
