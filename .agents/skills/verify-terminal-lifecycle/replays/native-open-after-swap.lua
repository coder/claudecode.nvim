-- OpenShowsLiveClaude: after you show another buffer in Claude's window, an open does not show Claude.
-- Path: you open Claude; in its window you run :e file; you run :ClaudeCodeOpen (terminal.open), or a send runs
-- terminal.ensure_visible.
-- Fixed in #451: the replay shows the promise kept. A BUG line means the finding is back.
local lib = dofile(os.getenv("REPLAY_LIB"))
local term = require("claudecode.terminal")
term.setup({ provider = "native", show_native_term_exit_tip = false }, "sh -c 'sleep 60'")
local file = vim.fn.getcwd() .. "/notes.txt"
vim.fn.writefile({ "my notes" }, file)

term.open()
lib.settle()
local claude = term.get_active_terminal_bufnr()
vim.cmd("stopinsert")
local claude_win = vim.api.nvim_get_current_win()
vim.cmd("edit " .. vim.fn.fnameescape(file))
lib.step(
  string.format(
    ":e notes.txt in Claude's window: Claude runs: %s, Claude shown in %d windows",
    tostring(#lib.running() == 1),
    lib.windows_showing(claude)
  )
)

for _, name in ipairs({ "ensure_visible", "open" }) do
  vim.cmd("wincmd p")
  vim.cmd("stopinsert")
  term[name]()
  local shown = lib.windows_showing(claude)
  local cur = vim.api.nvim_get_current_win()
  lib.step(
    string.format(
      "%s: Claude shown in %d windows; focus on %s",
      name,
      shown,
      cur == claude_win and "the window that shows notes.txt" or "your other window"
    ),
    shown == 0
  )
end
lib.finish()
