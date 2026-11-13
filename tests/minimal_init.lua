-- Minimal Neovim configuration for tests

-- Put the stub tests/bin/claude first on PATH so no test starts the host's real claude. Neovims that plenary's
-- test_file starts load this file again with the inherited PATH, so prepend only once.
local stub_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/bin"
local path = vim.env.PATH or ""
if path:sub(1, #stub_dir + 1) ~= stub_dir .. ":" then
  vim.env.PATH = stub_dir .. (path ~= "" and ":" .. path or "")
end

-- Neovim forks a pty job's child with its own signal handlers and resets them a few system calls after the fork.
-- A hangup in that window runs libuv's handler in the child. That handler writes into the signal pipe that the
-- child shares with Neovim, so Neovim reads a SIGHUP of its own and exits ("Caught deadly signal 'SIGHUP'").
-- Closing a job soon after termopen (a spec's after_each, or the quit that ends the file) can hit it, and under host
-- load a spec died that way. So termopen returns only once its child has run exec, and the child then has no
-- handler of Neovim's. Until exec the child's executable and its command line are Neovim's own. A program that is
-- Neovim again still has another command line. This needs /proc (Linux). Without it the window stays open.
local function read_proc(pid, name)
  local file = io.open("/proc/" .. pid .. "/" .. name, "rb")
  local text = file and file:read("*a")
  if file then
    file:close()
  end
  return text
end

local self_exe = vim.loop.fs_readlink("/proc/self/exe")
local self_cmdline = read_proc("self", "cmdline")
local real_termopen = vim.fn.termopen
vim.fn.termopen = function(...)
  local job = real_termopen(...)
  local ok, pid = pcall(vim.fn.jobpid, job)
  if self_exe and self_cmdline and ok then
    local deadline = vim.loop.hrtime() + 10e9
    while vim.loop.fs_readlink("/proc/" .. pid .. "/exe") == self_exe and read_proc(pid, "cmdline") == self_cmdline do
      assert(vim.loop.hrtime() < deadline, "the terminal job's child did not run exec within 10 s")
      vim.loop.sleep(1)
    end
  end
  return job
end

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
