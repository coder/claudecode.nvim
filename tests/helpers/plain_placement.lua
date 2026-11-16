-- The terminal provider specs fake a window model that has no buffer options and no autocmds. In it the placement
-- helper, `utils.win_set_buf_in_split`, is a plain `nvim_win_set_buf`. The helper has its own specs, in
-- tests/unit/utils_win_set_buf_spec.lua and, against a real Neovim, tests/integration/terminal_placement_spec.lua.
local M = {}

local installed = {}

---Replaces the helper of the loaded `claudecode.utils` with a plain swap. Call it after the provider is required.
function M.install()
  local utils = require("claudecode.utils")
  if installed[utils] == nil then
    installed[utils] = utils.win_set_buf_in_split
  end
  utils.win_set_buf_in_split = function(win, buf)
    vim.api.nvim_win_set_buf(win, buf)
    return true
  end
end

---Gives every replaced helper back. Call it in `after_each`.
function M.restore()
  for utils, original in pairs(installed) do
    utils.win_set_buf_in_split = original
  end
  installed = {}
end

return M
