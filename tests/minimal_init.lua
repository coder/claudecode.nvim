-- Minimal Neovim configuration for tests

-- Set up package path
local package_root = vim.fn.stdpath("data") .. "/site/pack/vendor/start/"
local install_path = package_root .. "plenary.nvim"

if vim.fn.empty(vim.fn.glob(install_path)) > 0 then
  vim.fn.system({
    "git",
    "clone",
    "--depth",
    "1",
    "https://github.com/nvim-lua/plenary.nvim",
    install_path,
  })
  vim.cmd([[packadd plenary.nvim]])
end

-- Add package paths for development
vim.opt.runtimepath:append(vim.fn.expand("$HOME/.local/share/nvim/site/pack/vendor/start/plenary.nvim"))
-- Add current working directory to runtime path for development
vim.opt.runtimepath:prepend(vim.fn.getcwd())

-- Set up test environment
vim.g.mapleader = " "
vim.g.maplocalleader = " "
vim.opt.termguicolors = true
vim.opt.timeoutlen = 300
vim.opt.updatetime = 250

-- Disable some built-in plugins
local disabled_built_ins = {
  "gzip",
  "matchit",
  "matchparen",
  "netrwPlugin",
  "tarPlugin",
  "tohtml",
  "tutor",
  "zipPlugin",
}

for _, plugin in pairs(disabled_built_ins) do
  vim.g["loaded_" .. plugin] = 1
end

-- Check for claudecode-specific tests by examining command line or environment
local should_load = false

-- Method 1: Check command line arguments for specific test files
for _, arg in ipairs(vim.v.argv) do
  if arg:match("command_args_spec") or arg:match("mcp_tools_spec") then
    should_load = true
    break
  end
end

-- Method 2: Check if CLAUDECODE_INTEGRATION_TEST env var is set
if not should_load and os.getenv("CLAUDECODE_INTEGRATION_TEST") == "true" then
  should_load = true
end

if not vim.g.loaded_claudecode and should_load then
  require("claudecode").setup({
    auto_start = false,
    log_level = "trace", -- More verbose for tests
  })
end

-- Global cleanup function for plenary test harness
_G.claudecode_test_cleanup = function()
  -- Clear global deferred responses
  if _G.claude_deferred_responses then
    _G.claude_deferred_responses = {}
  end

  -- Stop claudecode if running
  local ok, claudecode = pcall(require, "claudecode")
  if ok and claudecode.state and claudecode.state.server then
    local selection_ok, selection = pcall(require, "claudecode.selection")
    if selection_ok and selection.disable then
      selection.disable()
    end

    if claudecode.stop then
      claudecode.stop()
    end
  end
end

-- Auto-cleanup when using plenary test harness
if vim.env.PLENARY_TEST_HARNESS then
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      _G.claudecode_test_cleanup()
    end,
  })
end
