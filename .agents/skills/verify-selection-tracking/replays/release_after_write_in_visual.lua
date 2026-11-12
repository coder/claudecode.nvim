-- ReleaseSent / HeldUntilMoved: you change line 2 (the buffer is modified), select `alpha` on line 1, a :write saves the
-- file while you are in visual mode, and you press Esc inside the 100 ms debounce. The write moves the buffer's
-- changedtick and fires no on_lines, and the selection is untouched, so the flush on Esc must send it. Before #524 the
-- flush took the moved changedtick for an operator and Claude got the cursor. Default delays.
local driver = require("driver")
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta gamma", "second line" } } })
    vim.api.nvim_buf_set_lines(0, 1, 2, false, { "changed line" })
  end,
}, {
  { 20, "ve", "select alpha" },
  {
    10,
    function()
      vim.cmd("silent write")
    end,
    ":write while you are in visual mode",
  },
  { 10, "<Esc>", "release inside the debounce" },
}, function(_, sel)
  if sel and not sel.selection.isEmpty and sel.text == "alpha" then
    return true, "Claude holds the selection"
  end
  return false, string.format("Claude holds %s, not the selection that you released", driver.show(sel))
end)
