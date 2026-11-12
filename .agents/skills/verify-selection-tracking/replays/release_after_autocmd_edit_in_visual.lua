-- A known bug that the model does not cover (fix PR #540): an autocmd edits another line when visual mode starts (a
-- `ModeChanged` handler for `n:v`), and the Esc is already in the typeahead (`ve<Esc>`). The listener counts the edit and
-- schedules the check that would show that visual mode is still on, but no main-loop turn runs before the flush on Esc,
-- so the flush takes the edit for an operator's. Claude gets the cursor, not the selection, although its text is
-- untouched. BUG means the plugin still does that; the probe prints OK once the fix lands. Default delays.
local driver = require("driver")
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta gamma", "second line" } } })
    vim.api.nvim_create_autocmd("ModeChanged", {
      pattern = "n:v",
      once = true,
      callback = function()
        vim.api.nvim_buf_set_text(0, 1, 0, 1, 6, { "SECOND" })
      end,
    })
  end,
}, {
  { 20, "ve<Esc>", "select and release in one typeahead, a ModeChanged autocmd edits line 2" },
}, function(_, sel)
  if sel and not sel.selection.isEmpty and sel.text == "alpha" then
    return true, "Claude holds the selection"
  end
  return false, string.format("Claude holds %s, not the selection that you released", driver.show(sel))
end)
