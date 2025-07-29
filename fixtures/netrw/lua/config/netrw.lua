-- Netrw configuration for file browsing
-- This replaces file managers like nvim-tree or oil.nvim

-- Configure netrw settings early
vim.g.loaded_netrw = nil
vim.g.loaded_netrwPlugin = nil

-- Netrw settings
vim.g.netrw_banner = 0 -- Hide banner
vim.g.netrw_liststyle = 3 -- Tree view
vim.g.netrw_browse_split = 4 -- Open in previous window
vim.g.netrw_altv = 1 -- Split to the right
vim.g.netrw_winsize = 25 -- 25% width
vim.g.netrw_keepdir = 0 -- Keep current dir in sync
vim.g.netrw_localcopydircmd = "cp -r"

-- Hide dotfiles by default (toggle with gh)
vim.g.netrw_list_hide = [[.*\..*]]
vim.g.netrw_hide = 1

-- Use system open command
if vim.fn.has("mac") == 1 then
  vim.g.netrw_browsex_viewer = "open"
elseif vim.fn.has("unix") == 1 then
  vim.g.netrw_browsex_viewer = "xdg-open"
end
