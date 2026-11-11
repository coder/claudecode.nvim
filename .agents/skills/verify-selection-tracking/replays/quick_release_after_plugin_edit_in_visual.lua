-- A limit of the code that the model skips, not a rule: a plugin edits another line while you are in visual mode, and
-- you press Esc inside the 100 ms debounce. Entering visual mode records the changedtick, and the flush on Esc takes a
-- changed tick for an operator that consumed the selection, so it skips the selection. Claude gets the cursor, not
-- the selection you made, although its text is untouched. OK means the plugin does that.
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
  return sel and sel.selection.isEmpty and sel.selection.start.line == 0, "Claude holds the cursor, not the selection"
end)
