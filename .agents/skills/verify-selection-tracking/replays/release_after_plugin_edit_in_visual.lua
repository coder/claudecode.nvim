-- ReleaseSent / HeldUntilMoved: a plugin edits another line while you are in visual mode, and you press Esc inside the
-- 100 ms debounce, so nothing was sent in visual mode. The edit moves the buffer's changedtick but leaves the selection
-- on the screen, so the flush on Esc must send it. Before #524 the flush took a moved changedtick for an operator that
-- consumed the selection, and Claude got the cursor. Default delays.
local driver = require("driver")
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta gamma", "second line" } } })
  end,
}, {
  { 20, "ve", "select alpha" },
  {
    10,
    function()
      vim.api.nvim_buf_set_text(0, 1, 0, 1, 6, { "SECOND" })
    end,
    "a plugin edits line 2 while you are in visual mode",
  },
  { 10, "<Esc>", "release inside the debounce" },
}, function(_, sel)
  if sel and not sel.selection.isEmpty and sel.text == "alpha" then
    return true, "Claude holds the selection"
  end
  return false, string.format("Claude holds %s, not the selection that you released", driver.show(sel))
end)
