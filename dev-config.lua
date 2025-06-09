-- Development configuration for claudecode.nvim
-- This is Thomas's personal config for developing claudecode.nvim
-- Symlink this to your personal Neovim config:
-- ln -s ~/GitHub/claudecode.nvim/dev-config.lua ~/.config/nvim/lua/plugins/dev-claudecode.lua

return {
  "coder/claudecode.nvim",
  dev = true, -- Use local development version
  dir = "~/GitHub/claudecode.nvim", -- Adjust path as needed
  keys = {
    -- AI/Claude Code prefix
    { "<leader>a", nil, desc = "AI/Claude Code" },

    -- Core Claude commands
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },

    -- Context sending
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file from tree",
      ft = { "NvimTree", "neo-tree" },
    },

    -- Development helpers
    { "<leader>ao", "<cmd>ClaudeCodeOpen<cr>", desc = "Open Claude" },
    { "<leader>aq", "<cmd>ClaudeCodeClose<cr>", desc = "Close Claude" },
    { "<leader>ai", "<cmd>ClaudeCodeStatus<cr>", desc = "Claude Status" },
    { "<leader>aS", "<cmd>ClaudeCodeStart<cr>", desc = "Start Claude Server" },
    { "<leader>aQ", "<cmd>ClaudeCodeStop<cr>", desc = "Stop Claude Server" },
  },

  -- Development configuration
  opts = {
    -- auto_start = true,
    -- log_level = "debug",
    -- terminal_cmd = "claude --debug",
    -- terminal = {
    --   provider = "native",
    -- },
  },
}
