-- A limit that the model does not cover, not a rule: a plugin inserts a line above a held selection. The held range now
-- names other text, so the check that reads the range again finds that the selected text is not there and reports the
-- cursor. Claude loses the selection, although its text still exists one line lower. OK means the plugin does that.
local driver = require("driver")
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta gamma" } } })
  end,
}, {
  { 100, "ve", "select alpha" },
  { 200, "<Esc>", "release alpha" },
  {
    300,
    function()
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "inserted line" })
    end,
    "a plugin inserts a line above the held range",
  },
}, function(_, sel)
  return sel and sel.selection.isEmpty and sel.selection.start.line == 1,
    "Claude holds the cursor on the shifted line, not the selection"
end)
