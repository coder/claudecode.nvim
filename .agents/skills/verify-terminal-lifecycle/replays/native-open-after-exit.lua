-- OpenShowsLiveClaude: an open that runs after Claude exits but before the plugin's scheduled exit cleanup
-- focuses the dead terminal instead of starting Claude.
-- Path: you open Claude; Claude exits; an open runs (here a callback that a TermClose autocmd scheduled, so it
-- lands between the exit and the vim.schedule that native's on_exit queues); the exit cleanup runs.
-- Fixed in #451: the replay shows the promise kept. A BUG line means the finding is back.
local lib = dofile(os.getenv("REPLAY_LIB"))
local term = require("claudecode.terminal")
local auto_close = os.getenv("AUTO_CLOSE") ~= "false"
term.setup({ provider = "native", show_native_term_exit_tip = false, auto_close = auto_close }, "sh -c 'sleep 0.5'")

term.open()
local claude = term.get_active_terminal_bufnr()
lib.step(string.format("open (auto_close=%s): Claude runs in buffer %s", tostring(auto_close), tostring(claude)))
vim.cmd("stopinsert")

local seen
vim.api.nvim_create_autocmd("TermClose", {
  buffer = claude,
  once = true,
  callback = function()
    vim.schedule(function()
      term.open()
      local active = term.get_active_terminal_bufnr()
      seen = { active = active, running = #lib.running(), shown = active and lib.windows_showing(active) or 0 }
    end)
  end,
})
vim.wait(3000, function()
  return seen ~= nil
end, 10)
lib.wait(300)
lib.step("Claude exits; the open runs before the exit cleanup")
lib.step(
  string.format(
    "right after that open: it tracks buffer %s (the exited one: %s), %d Claude running",
    tostring(seen and seen.active),
    tostring(seen and seen.active == claude),
    seen and seen.running or -1
  ),
  seen ~= nil and seen.running == 0
)
local active = term.get_active_terminal_bufnr()
lib.step(
  string.format(
    "after the cleanup: tracked buffer %s, %d Claude running, exited buffer shown in %d windows",
    tostring(active),
    #lib.running(),
    vim.api.nvim_buf_is_valid(claude) and lib.windows_showing(claude) or 0
  ),
  #lib.running() == 0
)
lib.finish()
