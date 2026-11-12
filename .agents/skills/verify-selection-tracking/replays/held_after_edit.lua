-- NoDeletedText: release a selection, then press x on its last character without moving the cursor. Claude must
-- not keep text the buffer no longer has: the plugin reports the cursor once the held text changed. Default delays.
-- Before #452 the held selection survived until the cursor moved.
local driver = require("driver")
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta gamma" } } })
  end,
}, {
  { 50, "viw", "viw (select alpha)" },
  { 300, "<Esc>", "<Esc> (release it)" },
  { 300, "x", "x (delete the a under the cursor)" },
  { 300, "x", "x (and the space)" },
}, function(_, sel)
  local line = vim.api.nvim_get_current_line()
  if not sel or sel.selection.isEmpty then
    return true, "Claude holds the cursor"
  end
  local s, e = sel.selection.start.character, sel.selection["end"].character
  local there = line:sub(s + 1, e)
  return there == sel.text,
    string.format("Claude holds %q at %d-%d, the buffer has %q there (line %q)", sel.text, s, e, there, line)
end)
