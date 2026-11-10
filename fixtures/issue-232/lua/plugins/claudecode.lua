-- Load the local claudecode.nvim checkout (resolved in lua/config/lazy.lua).
--
-- Provider and the terminal command are env-controlled so the SAME fixture
-- reproduces the bug (snacks) and shows the baseline (native):
--   CLAUDECODE_PROVIDER=snacks|native   (default: snacks)
--
-- terminal_cmd points at fake-claude.sh -- a long-output, stays-alive stand-in
-- for the real Claude CLI, so the repro needs no network and no auth.
local provider = vim.env.CLAUDECODE_PROVIDER or "snacks"
local fake_claude = vim.g.claudecode_dev_dir .. "/fixtures/issue-232/fake-claude.sh"

return {
  "coder/claudecode.nvim",
  dir = vim.g.claudecode_dev_dir,
  dependencies = { "folke/snacks.nvim" },
  keys = {
    { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    { "<leader>af", "<cmd>ClaudeCodeFocus<cr>", desc = "Focus Claude" },
  },
  ---@type PartialClaudeCodeConfig
  opts = {
    auto_start = false, -- no server/port/lockfile needed for this UI repro
    log_level = "debug",
    terminal_cmd = fake_claude,
    terminal = {
      provider = provider,
      split_side = "right",
      split_width_percentage = 0.45,
      auto_close = false,
    },
  },
}
