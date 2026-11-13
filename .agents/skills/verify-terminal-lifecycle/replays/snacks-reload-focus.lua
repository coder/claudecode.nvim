-- HideKeepsClaude: after a reload, a hide of an adopted snacks split must leave the cursor where Neovim puts it, as on a
-- terminal that the provider started itself. Snacks' WinClosed handler is bound to the id of one window, and a window that the
-- provider re-created (a hide and a show) has no such handler on a terminal that the provider started. The wrapper registered
-- one for the re-created window, and Snacks' handler then ran `wincmd p` when that window closed, so the cursor went to the
-- previous window and not to the neighbor that Neovim picks.
-- Path (layout a.txt | b.txt | Claude on the right; 0 to 2 reloads): you open Claude; the plugin reloads; a toggle adopts and
-- hides it; a toggle shows it; from a.txt you focus Claude and then hide it with the focus toggle, twice. The cursor must be in
-- b.txt after each hide.
-- Main has no bug here. The replay guards the wrapper that #482 builds: a BUG line means a hide moved the cursor to the
-- previous window.
local lib = dofile(os.getenv("REPLAY_LIB"))
vim.fn.writefile({ "file a" }, vim.fn.getcwd() .. "/a.txt")
vim.fn.writefile({ "file b" }, vim.fn.getcwd() .. "/b.txt")

local function setup()
  local term = require("claudecode.terminal")
  term.setup({ provider = "snacks", auto_close = true }, "sh -c 'sleep 60'")
  return term
end

local function current_file()
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
end

for reloads = 0, 2 do
  lib.attempt(string.format("%d reload(s)", reloads), function()
    vim.cmd("silent! %bwipeout!")
    vim.cmd("silent! only")
    vim.cmd("edit a.txt")
    vim.cmd("rightbelow vsplit b.txt")
    vim.cmd("wincmd t")
    local term = lib.reload(setup)
    term.open()
    lib.settle()
    vim.cmd("stopinsert")
    for _ = 1, reloads do
      term = lib.reload(setup)
    end
    term.simple_toggle() -- adopts, and hides
    term.simple_toggle() -- shows it in a new window
    lib.settle()
    vim.cmd("stopinsert")
    for round = 1, 2 do
      vim.cmd("wincmd t")
      lib.settle()
      term.focus_toggle() -- focuses Claude
      lib.settle()
      term.focus_toggle() -- hides it
      lib.settle()
      lib.step(
        string.format(
          "%d reload(s), round %d: a hide of Claude leaves the cursor in %s",
          reloads,
          round,
          current_file()
        ),
        current_file() ~= "b.txt"
      )
      term.simple_toggle()
      lib.settle()
      vim.cmd("stopinsert")
    end
  end)
  for _, buf in ipairs(lib.running()) do
    vim.b[buf].claudecode_snacks_terminal = nil
    pcall(vim.fn.jobstop, vim.bo[buf].channel)
  end
  lib.wait(300)
end
lib.finish()
