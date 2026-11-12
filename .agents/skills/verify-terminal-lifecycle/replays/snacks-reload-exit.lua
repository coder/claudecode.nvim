-- OpenShowsLiveClaude and AtMostOneClaude: with the snacks provider and auto_close, an entry that runs between Claude's
-- exit and the provider's close shows the dead terminal, and the close then wipes it. And the Claude that such an entry
-- starts is dropped from Snacks.terminal.list() by that late wipe, so the next reload cannot find it, and the next open
-- starts a second Claude beside it. Snacks keys an instance by its command, directory, env and count, and it clears
-- the key when a buffer is wiped, whichever instance holds it.
-- Path, for each entry and each order: you open Claude (snacks); the plugin reloads (:Lazy reload) and an open adopts
-- that Claude; Claude exits; a TermClose autocmd calls the entry, either one that you defined before Claude started
-- (autocmds run in definition order, so it runs before Snacks' handler) or one defined after (it runs after);
-- the plugin reloads again; you open Claude.
-- The first Claude exits after 0.5 s. Every later one runs for a minute (a stub script tells them apart by a flag file).
-- Fixed in #482: the replay shows the promise kept. A BUG line means the finding is back.
local lib = dofile(os.getenv("REPLAY_LIB"))
local dir = vim.fn.getcwd()
local flag = dir .. "/claude-ran-before"
local stub = dir .. "/claude-stub.sh"
vim.fn.writefile({
  "#!/bin/sh",
  'if [ -e "' .. flag .. '" ]; then exec sleep 60; fi',
  'touch "' .. flag .. '"',
  "sleep 0.5",
}, stub)
local function setup()
  local term = require("claudecode.terminal")
  term.setup({ provider = "snacks", auto_close = true }, "sh " .. stub)
  return term
end

local entries = {
  open = function()
    require("claudecode.terminal").open()
  end,
  ensure_visible = function()
    require("claudecode.terminal").ensure_visible()
  end,
  simple_toggle = function()
    require("claudecode.terminal").simple_toggle()
  end,
  focus_toggle = function()
    require("claudecode.terminal").focus_toggle()
  end,
}

local claude, entry, seen
local function run_entry()
  if seen then
    return
  end
  entry()
  seen = { active = require("claudecode.terminal").get_active_terminal_bufnr(), running = #lib.running() }
end

-- Defined before any Claude starts, so it runs before the handler of every Claude that Snacks starts.
local early = false
vim.api.nvim_create_autocmd("TermClose", {
  callback = function(args)
    if early and args.buf == claude then
      run_entry()
    end
  end,
})

for _, order in ipairs({ "before", "after" }) do
  for _, name in ipairs({ "open", "ensure_visible", "simple_toggle", "focus_toggle" }) do
    local label = string.format("%s, autocmd %s the handler", name, order)
    entry, seen, early = entries[name], nil, order == "before"
    vim.fn.delete(flag)
    local term = lib.reload(setup)
    term.open()
    lib.settle()
    vim.cmd("stopinsert")
    term = lib.reload(setup)
    term.open()
    claude = term.get_active_terminal_bufnr()
    if order == "after" then
      vim.api.nvim_create_autocmd("TermClose", { buffer = claude, once = true, callback = run_entry })
    end
    lib.step(string.format("%s: Claude runs in buffer %s after a reload", label, tostring(claude)))

    vim.wait(3000, function()
      return seen ~= nil
    end, 10)
    lib.wait(500)
    lib.step(
      string.format(
        "  Claude exits; the entry runs: it tracks buffer %s (the exited one: %s), %d Claude running",
        tostring(seen and seen.active),
        tostring(seen and seen.active == claude),
        seen and seen.running or -1
      ),
      seen == nil or seen.active == claude or seen.running ~= 1
    )
    local second = seen and seen.active
    term = lib.reload(setup)
    term.open()
    lib.settle()
    lib.step(
      string.format(
        "  reload, then open: tracks buffer %s (the second Claude: %s), %d Claude running",
        tostring(term.get_active_terminal_bufnr()),
        tostring(term.get_active_terminal_bufnr() == second),
        #lib.running()
      ),
      #lib.running() ~= 1 or term.get_active_terminal_bufnr() ~= second
    )
    for _, buf in ipairs(lib.running()) do
      -- Without its mark, the provider does not report the stop as an error exit.
      vim.b[buf].claudecode_snacks_terminal = nil
      pcall(vim.fn.jobstop, vim.bo[buf].channel)
    end
    lib.wait(300)
    vim.cmd("silent! %bwipeout!")
  end
end
lib.finish()
