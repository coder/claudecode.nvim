-- Development configuration for claudecode.nvim
-- This is Thomas's personal config for developing claudecode.nvim
-- Symlink this to your personal Neovim config:
-- ln -s ~/projects/claudecode.nvim/dev-config.lua ~/.config/nvim/lua/plugins/dev-claudecode.lua

return {
  "coder/claudecode.nvim",
  dev = true, -- Use local development version
  keys = {
    -- AI/Claude Code prefix
    { "<leader>a", nil, desc = "AI/Claude Code" },

    -- Core Claude commands
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
    { "<leader>ar", "<cmd>ClaudeCode --resume<cr>", desc = "Resume Claude" },
    { "<leader>aC", "<cmd>ClaudeCode --continue<cr>", desc = "Continue Claude" },
    { "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Claude model" },

    -- Context sending
    { "<leader>as", "<cmd>ClaudeCodeAdd %<cr>", mode = "n", desc = "Add current buffer" },
    { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude" },
    {
      "<leader>as",
      "<cmd>ClaudeCodeTreeAdd<cr>",
      desc = "Add file from tree",
      ft = { "NvimTree", "neo-tree", "oil", "minifiles", "netrw" },
    },

    -- Development helpers
    { "<leader>ao", "<cmd>ClaudeCodeOpen<cr>", desc = "Open Claude" },
    { "<leader>aq", "<cmd>ClaudeCodeClose<cr>", desc = "Close Claude" },
    { "<leader>ai", "<cmd>ClaudeCodeStatus<cr>", desc = "Claude Status" },
    { "<leader>aS", "<cmd>ClaudeCodeStart<cr>", desc = "Start Claude Server" },
    { "<leader>aQ", "<cmd>ClaudeCodeStop<cr>", desc = "Stop Claude Server" },

    -- Diff management (buffer-local, only active in diff buffers)
    { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
    { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny diff" },
  },

  -- Development configuration - all options shown with defaults commented out
  ---@type PartialClaudeCodeConfig
  opts = {
    -- Server Configuration
    -- port_range = { min = 10000, max = 65535 }, -- WebSocket server port range
    -- auto_start = true, -- Auto-start server on Neovim startup
    -- log_level = "info", -- "trace", "debug", "info", "warn", "error"
    -- terminal_cmd = nil, -- Custom terminal command (default: "claude")

    -- Send/Focus Behavior
    focus_after_send = true, -- Focus Claude terminal after successful send while connected

    -- Selection Tracking
    -- track_selection = true, -- Enable real-time selection tracking
    -- visual_demotion_delay_ms = 50, -- Delay before demoting visual selection (ms)

    -- Connection Management
    -- connection_wait_delay = 200, -- Wait time after connection before sending queued @ mentions (ms)
    -- connection_timeout = 10000, -- Max time to wait for Claude Code connection (ms)
    -- queue_timeout = 5000, -- Max time to keep @ mentions in queue (ms)

    -- Diff Integration
    -- diff_opts = {
    --   layout = "horizontal", -- "vertical" or "horizontal" diff layout
    --   open_in_new_tab = true, -- Open diff in a new tab (false = use current tab)
    --   keep_terminal_focus = true, -- Keep focus in terminal after opening diff
    --   hide_terminal_in_new_tab = true, -- Hide Claude terminal in the new diff tab for more review space
    -- },

    -- Terminal Configuration
    -- terminal = {
    --   split_side = "right",                     -- "left" or "right"
    --   split_width_percentage = 0.30,            -- Width as percentage (0.0 to 1.0)
    --   provider = "auto",                        -- "auto", "snacks", or "native"
    --   show_native_term_exit_tip = true,         -- Show exit tip for native terminal
    --   auto_close = true,                        -- Auto-close terminal after command completion
    --   snacks_win_opts = {},                     -- Opts to pass to `Snacks.terminal.open()`
    -- },

    -- Development overrides (uncomment as needed)
    -- log_level = "debug",
    -- terminal = {
    --   provider = "native",
    --   auto_close = false, -- Keep terminals open to see output
    -- },
  },
}
