-- A limit of the code that the model skips, not a rule: a mapping edits another line while you are in visual mode and
-- presses Esc in the same typeahead (`<Cmd>lua ...<CR><Esc>`). The listener counts the edit and schedules the check that
-- would show that visual mode is still on, but no main-loop turn runs between the edit and the Esc, so the flush on Esc
-- finds an edit that nobody checked and takes it for an operator's. Claude gets the cursor, not the selection, although
-- its text is untouched. A plugin edit from a timer, a job or an autocmd is not like this: the check runs before the
-- next key (`release_after_plugin_edit_in_visual.lua`). OK means the plugin does that.
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
  return sel and sel.selection.isEmpty and sel.selection.start.line == 0, "Claude holds the cursor, not the selection"
end)
