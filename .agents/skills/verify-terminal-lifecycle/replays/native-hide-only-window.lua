-- HideNoError: the native toggle raises E444 when Claude's window is the only window.
-- Path: you open Claude, you run :only in its window, you run :ClaudeCode (simple_toggle) or :ClaudeCodeFocus.
-- Fixed in #451: the replay shows the promise kept. A BUG line means the finding is back.
local lib = dofile(os.getenv("REPLAY_LIB"))
local term = require("claudecode.terminal")
term.setup({ provider = "native", show_native_term_exit_tip = false }, "sh -c 'sleep 60'")

term.open()
lib.settle()
local claude = term.get_active_terminal_bufnr()
lib.step(string.format("open: Claude runs in buffer %s, %d windows", tostring(claude), #vim.api.nvim_list_wins()))
vim.cmd("stopinsert")
vim.cmd("only")
lib.step(string.format(":only in Claude's window: %d window", #vim.api.nvim_list_wins()))

for _, name in ipairs({ "simple_toggle", "focus_toggle" }) do
  local ok, err = pcall(term[name])
  local msg = ok and "no error" or tostring(err):match("E%d+:[^\n]*") or tostring(err)
  lib.step(string.format("%s: %s; Claude still runs: %s", name, msg, tostring(#lib.running() == 1)), not ok)
end
lib.finish()
