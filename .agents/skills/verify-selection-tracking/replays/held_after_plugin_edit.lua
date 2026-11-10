-- NoDeletedText: a plugin (or a reload, or a command) changes the held text away from the cursor. TextChanged fires,
-- CursorMoved does not, so only the TextChanged handler can end the hold. Claude must not keep text the buffer no
-- longer has. Default delays.
local driver = require("driver")
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta", "gamma delta" } } })
  end,
}, {
  { 50, "Vj", "Vj (select both lines)" },
  { 300, "<Esc>", "<Esc> (release it)" },
  {
    300,
    function()
      vim.api.nvim_buf_set_text(0, 0, 0, 0, 6, {})
    end,
    "a plugin deletes 'alpha ' on line 1 (cursor stays on line 2)",
  },
}, function(_, sel)
  if not sel or sel.selection.isEmpty then
    return true, "Claude holds the cursor"
  end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return false, string.format("Claude holds %q, but the buffer is %q", sel.text, table.concat(lines, "\n"))
end)
