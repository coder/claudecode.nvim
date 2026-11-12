-- AtMostOneClaude: with the snacks provider, an autocmd that calls open while a start runs starts a second Claude.
-- (The native provider marks its buffer before termopen for this case, see native_terminal_toggle_spec.lua.)
-- Path: you open Claude (snacks); a TermOpen autocmd calls open while Snacks.terminal.open runs; the start returns.
-- Fixed in #451: the replay shows the promise kept. A BUG line means the finding is back.
local lib = dofile(os.getenv("REPLAY_LIB"))
local term = require("claudecode.terminal")
term.setup({ provider = "snacks", auto_close = true }, "sh -c 'sleep 60'")
lib.step("provider in use is snacks: " .. tostring(require("claudecode.terminal.snacks").is_available()))

local reentered = false
vim.api.nvim_create_autocmd("TermOpen", {
  callback = function()
    if not reentered then
      reentered = true
      term.open()
    end
  end,
})
term.open()
lib.settle()
local tracked = term.get_active_terminal_bufnr()
lib.step(
  string.format(
    "open (a TermOpen autocmd calls open once): %d Claude running, tracked buffer %s",
    #lib.running(),
    tostring(tracked)
  ),
  #lib.running() > 1
)
term.close()
lib.wait(300)
lib.step(string.format(":ClaudeCodeClose: %d Claude running", #lib.running()), #lib.running() > 0)
lib.finish()
