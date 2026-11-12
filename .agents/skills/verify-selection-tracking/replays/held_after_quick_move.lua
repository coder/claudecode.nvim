-- HeldEndsWhenMoved: release a selection, then move away and back faster than the 100 ms debounce. Claude must
-- hold the cursor, not the selection: the plugin notes the move when CursorMoved fires, not when the debounce
-- fires. Default delays. Before #452 it compared the cursor only at the debounce and kept the selection.
local driver = require("driver")
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta gamma" } } })
  end,
}, {
  { 50, "ve", "ve (select alpha)" },
  { 300, "<Esc>", "<Esc> (release it)" },
  { 300, "l", "l (move right)" },
  { 30, "h", "h (back, 30 ms later)" },
}, function(_, sel)
  local cursor = vim.api.nvim_win_get_cursor(0)
  if sel and sel.selection.isEmpty and sel.selection.start.character == cursor[2] then
    return true, "Claude holds the cursor"
  end
  return false,
    string.format("the cursor moved after the release, but Claude still holds %q", sel and sel.text or "nil")
end)
