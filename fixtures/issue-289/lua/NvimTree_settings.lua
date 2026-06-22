-- AFFECTED FILE (NvimTree variant) for issue #289.
--
-- Same bug as `_neo-tree_.lua`, but triggered by the
-- `string.match(current_bufname, "NvimTree")` substring check. Filetype is
-- still `lua`; only the path contains "NvimTree".

local M = {}

M.opts = {
  sort = { sorter = "case_sensitive" },
  view = { width = 30 },
  renderer = { group_empty = true },
  filters = { dotfiles = true },
}

return M
