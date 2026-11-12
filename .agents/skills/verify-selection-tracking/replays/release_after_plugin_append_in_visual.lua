-- ReleaseSent / HeldUntilMoved: a plugin appends lines to the end of the buffer while you are in visual mode, and you
-- press Esc inside the 100 ms debounce. The selection is untouched and still on the screen, so the flush on Esc must
-- send it, although the changedtick moved. Before #524 Claude got the cursor. Default delays.
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
      vim.api.nvim_buf_set_lines(0, -1, -1, false, { "appended one", "appended two" })
    end,
    "a plugin appends two lines while you are in visual mode",
  },
  { 10, "<Esc>", "release inside the debounce" },
}, function(_, sel)
  if sel and not sel.selection.isEmpty and sel.text == "alpha" then
    return true, "Claude holds the selection"
  end
  return false, string.format("Claude holds %s, not the selection that you released", driver.show(sel))
end)
