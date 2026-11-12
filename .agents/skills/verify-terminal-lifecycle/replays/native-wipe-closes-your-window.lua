-- ExitClosesOnlyOwnWindow: with auto_close, the native exit cleanup closes the window that showed Claude even
-- though that window shows your file now, when Claude's buffer was wiped.
-- Path: you open Claude; in its window you run :e notes.txt; you wipe Claude's buffer (:bwipeout!, as a
-- buffer-delete plugin does); the job ends and the scheduled exit cleanup runs.
-- Fixed in #451: the replay shows the promise kept. A BUG line means the finding is back.
local lib = dofile(os.getenv("REPLAY_LIB"))
local term = require("claudecode.terminal")
term.setup({ provider = "native", show_native_term_exit_tip = false, auto_close = true }, "sh -c 'sleep 60'")
local file = vim.fn.getcwd() .. "/notes.txt"
vim.fn.writefile({ "my notes" }, file)

term.open()
lib.settle()
local claude = term.get_active_terminal_bufnr()
vim.cmd("stopinsert")
local notes_win = vim.api.nvim_get_current_win()
vim.cmd("edit " .. vim.fn.fnameescape(file))
lib.step(string.format(":e notes.txt in Claude's window: %d windows", #vim.api.nvim_list_wins()))
vim.cmd("bwipeout! " .. claude)
lib.step(
  string.format(
    ":bwipeout! Claude's buffer: %d windows, notes.txt window open: %s",
    #vim.api.nvim_list_wins(),
    tostring(vim.api.nvim_win_is_valid(notes_win))
  )
)
lib.wait(500)
lib.step(
  string.format(
    "after the exit cleanup: %d windows, notes.txt window open: %s",
    #vim.api.nvim_list_wins(),
    tostring(vim.api.nvim_win_is_valid(notes_win))
  ),
  not vim.api.nvim_win_is_valid(notes_win)
)
lib.finish()
