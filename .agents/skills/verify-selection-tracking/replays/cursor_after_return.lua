-- ClaudeSeesCursor: with visual_demotion_delay_ms longer than two debounces (here 1000 ms), release a selection,
-- move right, wait, move back. Claude must not keep the cursor position you left. Before #452 it did.
-- DELAY_MS=50 (the default delay) reruns the same keys.
local driver = require("driver")
local delay = tonumber(os.getenv("DELAY_MS") or "1000")
driver.run({
  setup = { visual_demotion_delay_ms = delay },
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta" } } })
  end,
}, {
  { 50, "ve", "ve (select alpha)" },
  { 300, "<Esc>", "<Esc> (release it)" },
  { 250, "l", "l (move right)" },
  { 250, "h", "h (move back)" },
}, function(_, sel)
  local cursor = vim.api.nvim_win_get_cursor(0)
  if not sel or not sel.selection.isEmpty or sel.selection.start.character == cursor[2] then
    return true, "Claude holds the cursor where it is, or the held selection"
  end
  return false,
    string.format("the cursor is at 0:%d, Claude holds the cursor at 0:%d", cursor[2], sel.selection.start.character)
end)
