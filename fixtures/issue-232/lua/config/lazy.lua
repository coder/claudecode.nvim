-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Resolve the claudecode.nvim checkout that owns this fixture (XDG_CONFIG_HOME is
-- the `fixtures/` dir under the `vv` launcher, so its parent is the repo root).
-- Works from a normal checkout or a git worktree.
local repo_root = vim.fn.fnamemodify(vim.env.XDG_CONFIG_HOME or vim.fn.getcwd(), ":h")
vim.g.claudecode_dev_dir = repo_root

require("lazy").setup({
  spec = {
    { import = "plugins" },
  },
  install = { colorscheme = { "habamax" } },
  checker = { enabled = false },
})

-- Window navigation like the issue reporter's setup (Ctrl-h / Ctrl-l). The
-- terminal-mode maps leave terminal mode FIRST, then move -- so any jump back to
-- the bottom is caused by the provider re-entering insert mode, not by the maps.
vim.keymap.set("n", "<C-h>", "<C-w>h", { silent = true, desc = "Window left" })
vim.keymap.set("n", "<C-l>", "<C-w>l", { silent = true, desc = "Window right" })
vim.keymap.set("t", "<C-h>", [[<C-\><C-n><C-w>h]], { silent = true, desc = "Window left (from terminal)" })
vim.keymap.set("t", "<C-l>", [[<C-\><C-n><C-w>l]], { silent = true, desc = "Window right (from terminal)" })
vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], { silent = true, desc = "Exit terminal mode (double esc)" })

-- Make the current mode + window visible in EVERY window's statusline so a
-- terminal snapshot reveals whether we landed in Normal ('n') or Terminal ('t')
-- mode after switching back.
vim.o.laststatus = 2
vim.o.statusline = " MODE=%{mode()}  win=%{winnr()}  %f "

-- One-shot layout helper so the reproduction is deterministic and scriptable:
--   1. edit the sample file in the left window
--   2. open the Claude terminal (focused) in a right split
-- After calling this you are IN the terminal, in terminal mode, at the bottom.
_G.repro_setup = function()
  vim.cmd("edit " .. vim.fn.fnameescape(vim.g.claudecode_dev_dir .. "/fixtures/issue-232/example/notes.md"))
  require("claudecode.terminal").simple_toggle({}, nil)
end
vim.api.nvim_create_user_command("Repro", _G.repro_setup, { desc = "Set up issue #232 reproduction layout" })

vim.schedule(function()
  local provider = vim.env.CLAUDECODE_PROVIDER or "snacks"
  vim.notify(
    ("[issue-232] provider=%s  -- run :Repro (or <leader>r), then in the terminal: <C-\\><C-n>, gg, <C-h>, <C-l>"):format(
      provider
    ),
    vim.log.levels.INFO
  )
end)

vim.keymap.set("n", "<leader>r", "<cmd>Repro<cr>", { desc = "issue-232 repro layout" })
