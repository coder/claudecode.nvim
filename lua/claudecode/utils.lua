--- Shared utility functions for claudecode.nvim
-- @module claudecode.utils

local M = {}

--- Normalizes focus parameter to default to true for backward compatibility
--- @param focus boolean|nil The focus parameter
--- @return boolean Normalized focus value
function M.normalize_focus(focus)
  return focus == nil and true or focus
end

return M
