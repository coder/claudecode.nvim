-- Development configuration for claudecode.nvim with Snacks Explorer.
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
    { "<leader>as", "<cmd>ClaudeCodeAdd %<cr>", mode = "n", desc = "Add current buffer" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    { "<leader>ao", "<cmd>ClaudeCodeOpen<cr>", desc = "Open Claude" },
    { "<leader>aq", "<cmd>ClaudeCodeClose<cr>", desc = "Close Claude" },
    { "<leader>aS", "<cmd>ClaudeCodeStart<cr>", desc = "Start Claude Server" },
    { "<leader>aQ", "<cmd>ClaudeCodeStop<cr>", desc = "Stop Claude Server" },
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },
  ---@type PartialClaudeCodeConfig
  opts = {
    -- Keep server manual/predictable for reproduction; tests start it explicitly.
    log_level = "debug",
  },
}
