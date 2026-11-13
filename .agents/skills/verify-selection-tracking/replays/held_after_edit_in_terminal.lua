-- NoDeletedText: Claude holds a selection of a.txt, you are in the Claude terminal in the same window (a.txt is in no
-- window), and a plugin deletes the selected text with nvim_buf_set_text. Neovim reports it to the buffer's listeners
-- only. Claude must not keep text that is gone until you come back. Default delays.
local driver = require("driver")
local file_buf
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta gamma" } } })
    file_buf = vim.api.nvim_get_current_buf()
  end,
}, {
  { 50, "ve", "ve (select alpha)" },
  { 300, "<Esc>", "<Esc> (release it)" },
  {
    300,
    function()
      vim.cmd("terminal sh -c 'sleep 20' claude")
    end,
    ":terminal ... claude (the Claude terminal, in a.txt's window)",
  },
  {
    300,
    function()
      vim.cmd("stopinsert")
    end,
    "stopinsert",
  },
  {
    300,
    function()
      vim.api.nvim_buf_set_text(file_buf, 0, 0, 0, 6, {})
    end,
    "a plugin deletes 'alpha ' in a.txt",
  },
  { 300, function() end, "wait" },
}, function(_, sel)
  if not sel or sel.selection.isEmpty then
    return true, "Claude holds the cursor"
  end
  local lines = vim.api.nvim_buf_get_lines(file_buf, 0, -1, false)
  return false, string.format("Claude holds %q, but a.txt is %q", sel.text, table.concat(lines, "|"))
end)
