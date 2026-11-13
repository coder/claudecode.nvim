-- NoDeletedText: Claude holds a selection of a.txt, you are in the Claude terminal, and Claude rewrites a.txt on disk
-- without the selected text. Neovim reloads the file (autoread, here `:checktime`), and TextChanged does not fire
-- for a buffer that is not current. Claude must not keep text that is gone until you come back. Default delays.
local driver = require("driver")
local file_buf, path
driver.run({
  prepare = function()
    driver.files({ { "a.txt", { "alpha beta gamma" } } })
    file_buf = vim.api.nvim_get_current_buf()
    path = vim.api.nvim_buf_get_name(file_buf)
  end,
}, {
  { 50, "ve", "ve (select alpha)" },
  { 300, "<Esc>", "<Esc> (release it)" },
  {
    300,
    function()
      vim.cmd("vsplit | terminal sh -c 'sleep 20' claude")
    end,
    ":vsplit | :terminal ... claude (a.txt stays in its window)",
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
      vim.fn.writefile({ "beta gamma" }, path)
      local later = os.time() + 10
      (vim.uv or vim.loop).fs_utime(path, later, later) -- a modification time that Neovim sees as new
      vim.cmd("checktime " .. file_buf)
    end,
    "Claude rewrites a.txt without 'alpha ', :checktime reloads it",
  },
  { 300, function() end, "wait" },
}, function(_, sel)
  if not sel or sel.selection.isEmpty then
    return true, "Claude holds the cursor"
  end
  local lines = vim.api.nvim_buf_get_lines(file_buf, 0, -1, false)
  return false, string.format("Claude holds %q, but a.txt is %q", sel.text, table.concat(lines, "|"))
end)
