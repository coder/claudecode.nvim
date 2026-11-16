--- LD_PRELOAD splits its value at spaces and colons, so a path that holds one of them cannot name a shim: ld.so reads
--- the pieces as separate objects and ignores them. A TMPDIR can hold either one (CI also runs the suite under
--- "odd tmp 50%").
local M = {}

---@param path string
---@return boolean can_name_a_shim
function M.can_name_a_shim(path)
  return not path:find("[ :]")
end

return M
