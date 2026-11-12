-- NoDeletedText: a plugin (or a reload, or a command) changes the held text away from the cursor. TextChanged fires,
-- CursorMoved does not. The TextChanged handler ends the hold, and so does the buffer listener (on_lines fires for an
-- edit of the current buffer too), so this probe also passes with the TextChanged call removed: it does not prove
-- that guard on its own (see SKILL.md, "Read the result"). Claude must not keep text the buffer no longer has.
-- Default delays.
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
