if vim.fn.has("nvim-0.8.0") ~= 1 then
  vim.api.nvim_err_writeln("OpenCode requires Neovim >= 0.8.0")
  return
end

if vim.g.loaded_opencode then
  return
end
vim.g.loaded_opencode = 1

--- Example: In your `init.lua`, you can set `vim.g.opencode_auto_setup = { auto_start = true }`
--- to automatically start OpenCode when Neovim loads.
if vim.g.opencode_auto_setup then
  vim.defer_fn(function()
    require("opencode").setup(vim.g.opencode_auto_setup)
  end, 0)
end

-- Commands are now registered in lua/opencode/init.lua's _create_commands function
-- when require("opencode").setup() is called.
-- This file (plugin/opencode.lua) is primarily for the load guard
-- and the optional auto-setup mechanism.

local main_module_ok, _ = pcall(require, "opencode")
if not main_module_ok then
  vim.notify("OpenCode: Failed to load main module. Plugin may not function correctly.", vim.log.levels.ERROR)
end
