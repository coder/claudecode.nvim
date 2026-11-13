-- A bug that #540 fixed: a plugin edits another line from a timer callback while you are in visual mode, and your Esc
-- arrives (`nvim_input`, the way a UI sends a key) while that callback, or another callback that was queued before the
-- listener's check, still runs. The schedule that checks the edit runs after those callbacks, and the key was read
-- first, so the flush on Esc found an edit that nobody had checked and took it for an operator's: Claude got the
-- cursor, not the selection, although its text was untouched. Now the check also runs from a `vim.on_key` listener,
-- which sees the Esc before it is processed. This probe sends the key during the plugin's own callback. BUG means the
-- flush takes the edit for an operator's again. Default delays.
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
