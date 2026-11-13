-- A bug that #540 fixed: a mapping edits another line while you are in visual mode and presses Esc in the same typeahead
-- (`<Cmd>lua ...<CR><Esc>`). The listener counts the edit and schedules the check that shows that visual mode is still
-- on, but no main-loop turn runs between the edit and the Esc, so the flush on Esc found an edit that nobody had
-- checked and took it for an operator's: Claude got the cursor, not the selection, although its text was untouched.
-- Now the check also runs from a `vim.on_key` listener, which sees the Esc before it is processed. BUG means the flush
-- takes the edit for an operator's again. Two other ways to reach the same flush are
-- `release_with_key_during_plugin_callback.lua` and `release_after_autocmd_edit_in_visual.lua`. Default delays.
local driver = require("driver")
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta gamma", "second line" } } })
  end,
}, {
  { 20, "ve", "select alpha" },
  {
    10,
    "<Cmd>lua vim.api.nvim_buf_set_text(0, 1, 0, 1, 6, { 'SECOND' })<CR><Esc>",
    "a mapping edits line 2 and releases in the same typeahead",
  },
}, function(_, sel)
  if sel and not sel.selection.isEmpty and sel.text == "alpha" then
    return true, "Claude holds the selection"
  end
  return false, string.format("Claude holds %s, not the selection that you released", driver.show(sel))
end)
