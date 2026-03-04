-- Minimal repro config for claudecode.nvim issues.
--
-- This fixture intentionally avoids a plugin manager so it's easy to run and reason about.
--
-- Usage (from repo root):
--   source fixtures/nvim-aliases.sh
--   repro
--
-- To edit this config:
--   vve repro

-- Ensure this repo is on the runtimepath so `plugin/claudecode.lua` is loaded.
local config_dir = vim.fn.stdpath("config")
local repo_root = vim.fn.fnamemodify(config_dir, ":h:h")

vim.opt.rtp:prepend(repo_root)

-- Basic editor settings
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

claudecode.setup({
  auto_start = false, -- avoid noisy startup + make restarts deterministic
  log_level = "debug",
  terminal = {
    provider = "native",
    auto_close = false,
  },
  diff_opts = {
    layout = "vertical",
    open_in_new_tab = false,
    keep_terminal_focus = false,
  },
})

local function ensure_claudecode_started()
  local ok_start, started_or_err, port_or_err = pcall(function()
    return claudecode.start(false)
  end)

  if not ok_start then
    vim.notify("ClaudeCode start crashed: " .. tostring(started_or_err), vim.log.levels.ERROR)
    return false
  end

  local started = started_or_err
  if started then
    return true
  end

  -- start() returns false + "Already running" when running.
  if port_or_err == "Already running" then
    return true
  end

  vim.notify("ClaudeCode failed to start: " .. tostring(port_or_err), vim.log.levels.ERROR)
  return false
end

-- Keymaps (kept small on purpose)
vim.keymap.set("n", "<leader>ac", function()
  if ensure_claudecode_started() then
    local terminal = require("claudecode.terminal")
    terminal.simple_toggle({}, nil)
  end
end, { desc = "Toggle Claude" })

vim.keymap.set("n", "<leader>af", function()
  if ensure_claudecode_started() then
    local terminal = require("claudecode.terminal")
    terminal.focus_toggle({}, nil)
  end
end, { desc = "Focus Claude" })

vim.keymap.set("n", "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", { desc = "Accept diff" })
vim.keymap.set("n", "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", { desc = "Deny diff" })

-- Convenience helpers for iterating on this fixture.
vim.api.nvim_create_user_command("ReproEditConfig", function()
  local config_path = vim.fn.stdpath("config") .. "/init.lua"

  -- Open the config file without `:edit` / `vim.cmd(...)` so we don't trigger
  -- Treesitter "vim" language injections (which can be noisy if parsers/queries mismatch).
  local bufnr = vim.fn.bufadd(config_path)
  vim.fn.bufload(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
end, { desc = "Edit the repro Neovim config" })

vim.keymap.set("n", "<leader>ae", "<cmd>ReproEditConfig<cr>", { desc = "Edit repro config" })
vim.keymap.set("n", "<leader>aw", function()
  vim.notify(("windows in tab: %d"):format(vim.fn.winnr("$")))
end, { desc = "Claude: show window count" })
