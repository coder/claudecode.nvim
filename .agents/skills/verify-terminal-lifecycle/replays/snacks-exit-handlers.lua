-- With the snacks provider and auto_close, an entry that runs while Neovim dispatches TermClose, or after a reload
-- before any entry adopted the Claude, must neither delete the handlers that remain for that event nor lose a Claude.
-- Scenario 1: you open Claude; Claude exits with status 3; a TermClose autocmd that you defined before Claude started
-- (so it runs before Snacks' handler) calls open. A buffer-local autocmd that you defined after Claude started, and the
-- provider's own handler (it logs the exit status), must still run. A wipe inside the event deletes both.
-- Scenario 2: you open Claude; the plugin reloads and no entry adopts Claude; Claude exits; an open in the gap starts a
-- new Claude; the plugin reloads again; you open Claude. One Claude must run, and it must be the second one.
-- Fixed in #482: the replay shows the promise kept. A BUG line means the finding is back.
local lib = dofile(os.getenv("REPLAY_LIB"))
local dir = vim.fn.getcwd()
local flag = dir .. "/claude-ran-before"
local stub = dir .. "/claude-stub.sh"
-- The first Claude exits with status 3 after 0.5 s. Every later one runs for a minute.
vim.fn.writefile({
  "#!/bin/sh",
  'if [ -e "' .. flag .. '" ]; then exec sleep 60; fi',
  'touch "' .. flag .. '"',
  "sleep 0.5",
  "exit 3",
}, stub)
local exit_reports = 0
vim.notify = function(message)
  if tostring(message):find("exited with code", 1, true) then
    exit_reports = exit_reports + 1
  end
end
local function setup()
  local term = require("claudecode.terminal")
  term.setup({ provider = "snacks", auto_close = true }, "sh " .. stub)
  return term
end
local function stop_all()
  for _, buf in ipairs(lib.running()) do
    -- Without its mark, the provider does not report the stop as an error exit.
    vim.b[buf].claudecode_snacks_terminal = nil
    pcall(vim.fn.jobstop, vim.bo[buf].channel)
  end
  lib.wait(300)
  vim.cmd("silent! %bwipeout!")
end

local claude, entered, later_autocmd_ran
vim.api.nvim_create_autocmd("TermClose", {
  callback = function(args)
    if args.buf == claude and not entered then
      entered = true
      require("claudecode.terminal").open()
    end
  end,
})

vim.fn.delete(flag)
local term = lib.reload(setup)
term.open()
lib.settle()
vim.cmd("stopinsert")
claude = term.get_active_terminal_bufnr()
vim.api.nvim_create_autocmd("TermClose", {
  buffer = claude,
  callback = function()
    later_autocmd_ran = true
  end,
})
vim.wait(3000, function()
  return entered
end, 10)
lib.wait(500)
lib.step(
  "scenario 1: the entry ran inside TermClose; a later buffer-local autocmd ran: "
    .. tostring(later_autocmd_ran == true),
  not later_autocmd_ran
)
lib.step(
  "scenario 1: the provider's handler logged the exit status: " .. tostring(exit_reports == 1),
  exit_reports ~= 1
)
stop_all()

entered, later_autocmd_ran, exit_reports = false, nil, 0
vim.fn.delete(flag)
term = lib.reload(setup)
term.open()
lib.settle()
vim.cmd("stopinsert")
claude = term.get_active_terminal_bufnr()
term = lib.reload(setup)
lib.step("scenario 2: the plugin reloaded; no entry has adopted the running Claude yet")
vim.wait(3000, function()
  return entered
end, 10)
lib.wait(500)
local second = require("claudecode.terminal").get_active_terminal_bufnr()
lib.step(
  string.format(
    "scenario 2: the entry in the gap started buffer %s (the exited one: %s), %d Claude running",
    tostring(second),
    tostring(second == claude),
    #lib.running()
  ),
  second == nil or second == claude or #lib.running() ~= 1
)
term = lib.reload(setup)
term.open()
lib.settle()
local tracked = term.get_active_terminal_bufnr()
lib.step(
  string.format(
    "scenario 2: reload, then open: tracks buffer %s (the second Claude: %s), %d Claude running",
    tostring(tracked),
    tostring(tracked == second),
    #lib.running()
  ),
  #lib.running() ~= 1 or tracked ~= second
)
stop_all()
lib.finish()
