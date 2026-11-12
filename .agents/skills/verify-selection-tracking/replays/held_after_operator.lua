-- HeldEndsWhenMoved / NoDeletedText: a selection made backwards (cursor at its start), released with Esc, then
-- reselected with gv and deleted with d. The cursor ends where the first flush left it. Claude must hold the
-- cursor, not the deleted selection. Default delays. Before #452 the plugin took the deleted selection for a held one.
local driver = require("driver")
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta gamma" } } })
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
  end,
}, {
  { 50, "vb", "vb (select alpha backwards)" },
  { 300, "<Esc>", "<Esc> (release it)" },
  { 400, "gv", "gv (select it again)" },
  { 300, "d", "d (delete it)" },
}, function(_, sel)
  local line = vim.api.nvim_get_current_line()
  local cursor = vim.api.nvim_win_get_cursor(0)
  if sel and sel.selection.isEmpty and sel.selection.start.character == cursor[2] then
    return true, "Claude holds the cursor"
  end
  return false, string.format("Claude holds %q, but the line is now %q", sel and sel.text or "nil", line)
end)
