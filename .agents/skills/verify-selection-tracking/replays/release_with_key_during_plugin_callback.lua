-- A known bug that the model does not cover (fix PR #540): a plugin edits another line from a timer callback while you
-- are in visual mode, and your Esc arrives while that callback still runs (`nvim_input`, the way a UI sends a key). The
-- schedule that would check the edit runs after the callback, and the key was read first, so the flush on Esc takes the
-- edit for an operator's. Claude gets the cursor, not the selection, although its text is untouched. A plugin edit
-- whose callback ends before the next key is not like this (`release_after_plugin_edit_in_visual.lua`). BUG means the
-- plugin still does that; the probe prints OK once the fix lands. Default delays.
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
      vim.api.nvim_input("<Esc>") -- your key arrives while the plugin's callback runs
    end,
    "a plugin edits line 2 from a timer callback, and Esc arrives during that callback",
  },
}, function(_, sel)
  if sel and not sel.selection.isEmpty and sel.text == "alpha" then
    return true, "Claude holds the selection"
  end
  return false, string.format("Claude holds %s, not the selection that you released", driver.show(sel))
end)
