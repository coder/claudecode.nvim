-- OpenShowsLiveClaude: after a reload, an adopted snacks split that the provider hid and showed must still keep a file that
-- you open in its window out of Claude's window. Snacks' Win:show registers a BufWinEnter handler that moves such a file to
-- another window and puts Claude's buffer back. An adopted wrapper never ran Win:show, and the provider re-creates a split
-- without it, so the handler was missing: `:edit a.txt` in Claude's window replaced Claude's buffer, Claude had no window,
-- and the next toggle opened a second split.
-- Path (a split on the right, each with and without a reload and a hide and a show): you open Claude; the plugin reloads;
-- a toggle adopts and hides it; a toggle shows it; you run `:edit a.txt` in Claude's window. Claude must still show in
-- its window and the file must open in another window, and a toggle must hide that one window of Claude.
-- Main has no bug here. The replay guards the wrapper that #482 builds: a BUG line means a file replaced Claude's buffer.
local lib = dofile(os.getenv("REPLAY_LIB"))
vim.fn.writefile({ "file a" }, vim.fn.getcwd() .. "/a.txt")

local function setup()
  local term = require("claudecode.terminal")
  term.setup({ provider = "snacks", auto_close = true, auto_insert = false }, "sh -c 'sleep 60'")
  return term
end

local function file_name(buf)
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
end

for _, case in ipairs({
  { reload = false, cycle = false },
  { reload = false, cycle = true },
  { reload = true, cycle = false },
  { reload = true, cycle = true },
}) do
  local label = string.format("reload=%s, hide and show=%s", tostring(case.reload), tostring(case.cycle))
  lib.attempt(label, function()
    local term = lib.reload(setup)
    term.open()
    lib.settle()
    vim.cmd("stopinsert")
    local claude = term.get_active_terminal_bufnr()
    if case.reload then
      term = lib.reload(setup)
    end
    if case.cycle then
      term.simple_toggle()
      term.simple_toggle()
      lib.settle()
    end
    local win = vim.fn.win_findbuf(claude)[1]
    vim.api.nvim_set_current_win(win)
    vim.cmd("stopinsert")
    vim.cmd("edit a.txt")
    lib.wait(100)
    local in_claude_window = vim.api.nvim_win_is_valid(win) and file_name(vim.api.nvim_win_get_buf(win)) or "(closed)"
    local claude_windows = #vim.fn.win_findbuf(claude)
    term.simple_toggle()
    lib.wait(100)
    lib.step(
      string.format(
        "%s, then :edit a.txt in Claude's window: its window shows %s, %d Claude window(s), after a toggle %d, %d Claude running",
        label,
        in_claude_window,
        claude_windows,
        #vim.fn.win_findbuf(claude),
        #lib.running()
      ),
      claude_windows ~= 1 or in_claude_window == "a.txt" or #vim.fn.win_findbuf(claude) ~= 0 or #lib.running() ~= 1
    )
  end)
  for _, buf in ipairs(lib.running()) do
    vim.b[buf].claudecode_snacks_terminal = nil
    pcall(vim.fn.jobstop, vim.bo[buf].channel)
  end
  lib.wait(300)
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
end
lib.finish()
