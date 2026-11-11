-- OpenShowsLiveClaude: after a reload, an adopted snacks Claude must come back in the tab where you open it, also when
-- another tab shows a copy of the terminal's buffer (the diff in a new tab does that: it shows the terminal beside the
-- proposal). The adoption cannot know which window was the terminal's. It takes a window that Snacks made (it carries the
-- `snacks_win` marker, which the copy of a diff tab lacks), one of the current tab first, and then tracks the window that it
-- hides and shows itself, as an instance that the provider started does. A scan of every window at each entry took the copy
-- for the terminal's window: after a hide in the first tab, an open jumped to the diff tab and left the first tab without
-- Claude.
-- Paths (a split on the right):
-- 1. You open Claude; the plugin reloads; an entry adopts it (the diff asks for the terminal's buffer first); another tab shows
--    a copy of its buffer; in the first tab a toggle hides Claude; you open Claude. Claude must show in the first tab, you
--    must stay there, and the copy must stay. Then in the other tab a toggle must hide the window that the provider tracks
--    (the first tab's), not the copy, and the next toggle must show Claude in that tab too.
-- 2. Claude shows only in the first tab; the plugin reloads in a second tab; you open Claude there: you must land in the first
--    tab, on the one Claude window, as on a terminal that the provider started itself.
-- 3. Claude is hidden in the first tab and a second tab shows a copy; the plugin reloads; you open Claude in the first tab:
--    Claude must show there, and you must stay.
-- Main has no bug here. The replay guards the adopted window that #482 builds: a BUG line means the wrapper takes a copy in
-- another tab for the terminal's window, or does not find the window that Snacks made in another tab.
local lib = dofile(os.getenv("REPLAY_LIB"))

local function setup()
  local term = require("claudecode.terminal")
  term.setup({ provider = "snacks", auto_close = true, auto_insert = false }, "sh -c 'sleep 60'")
  return term
end

-- The windows of a tab that show the buffer.
local function windows_in(tab, buf)
  local count = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      count = count + 1
    end
  end
  return count
end

local function cleanup()
  for _, buf in ipairs(lib.running()) do
    vim.b[buf].claudecode_snacks_terminal = nil
    pcall(vim.fn.jobstop, vim.bo[buf].channel)
  end
  lib.wait(300)
  vim.cmd("silent! tabonly")
  vim.cmd("silent! only")
  vim.cmd("silent! %bwipeout!")
end

lib.attempt("a copy in another tab", function()
  local term = lib.reload(setup)
  term.open()
  lib.settle()
  vim.cmd("stopinsert")
  local first_tab = vim.api.nvim_get_current_tabpage()
  local claude = term.get_active_terminal_bufnr()
  term = lib.reload(setup)
  term.get_active_terminal_bufnr() -- adopts, as the diff does before it shows the terminal in its tab

  vim.cmd("tabnew")
  local other_tab = vim.api.nvim_get_current_tabpage()
  local copy = vim.api.nvim_get_current_win()
  vim.cmd("vsplit") -- the diff's own window stays beside the copy
  vim.api.nvim_win_set_buf(copy, claude)
  vim.api.nvim_set_current_tabpage(first_tab)

  term.simple_toggle()
  local before = windows_in(first_tab, claude)
  term.open()
  lib.settle()
  local after = windows_in(first_tab, claude)
  lib.step(
    string.format(
      "a copy in another tab: a hide in the first tab, then open: Claude windows in the first tab %d -> %d, in the other tab %d, you are in the %s tab, %d Claude running",
      before,
      after,
      windows_in(other_tab, claude),
      vim.api.nvim_get_current_tabpage() == first_tab and "first" or "other",
      #lib.running()
    ),
    after ~= 1
      or windows_in(other_tab, claude) ~= 1
      or vim.api.nvim_get_current_tabpage() ~= first_tab
      or #lib.running() ~= 1
  )

  vim.api.nvim_set_current_tabpage(other_tab)
  vim.api.nvim_set_current_win(copy)
  term.simple_toggle()
  local hid_first, kept_copy = windows_in(first_tab, claude), windows_in(other_tab, claude)
  lib.step(
    string.format(
      "a toggle in the other tab hides the tracked window: first tab %d, other tab %d (the copy stays)",
      hid_first,
      kept_copy
    ),
    hid_first ~= 0 or kept_copy ~= 1
  )
  term.simple_toggle()
  lib.settle()
  lib.step(
    string.format(
      "the next toggle shows Claude in the other tab too: first tab %d, other tab %d",
      windows_in(first_tab, claude),
      windows_in(other_tab, claude)
    ),
    windows_in(other_tab, claude) ~= 2 or #lib.running() ~= 1
  )
end)
cleanup()

lib.attempt("Claude only in the first tab", function()
  local term = lib.reload(setup)
  term.open()
  lib.settle()
  vim.cmd("stopinsert")
  local first_tab = vim.api.nvim_get_current_tabpage()
  local claude = term.get_active_terminal_bufnr()
  vim.cmd("tabnew")
  local other_tab = vim.api.nvim_get_current_tabpage()
  term = lib.reload(setup)
  term.open()
  lib.settle()
  lib.step(
    string.format(
      "Claude only in the first tab, a reload in a second tab, then open there: you are in the %s tab, Claude windows in the first tab %d, in the second tab %d, %d Claude running",
      vim.api.nvim_get_current_tabpage() == first_tab and "first" or "second",
      windows_in(first_tab, claude),
      windows_in(other_tab, claude),
      #lib.running()
    ),
    vim.api.nvim_get_current_tabpage() ~= first_tab
      or windows_in(first_tab, claude) ~= 1
      or windows_in(other_tab, claude) ~= 0
      or #lib.running() ~= 1
  )
  term.simple_toggle()
  lib.step(
    string.format("then a toggle hides it: Claude windows in the first tab %d", windows_in(first_tab, claude)),
    windows_in(first_tab, claude) ~= 0
  )
end)
cleanup()

lib.attempt("hidden in the first tab, a copy in another", function()
  local term = lib.reload(setup)
  term.open()
  lib.settle()
  vim.cmd("stopinsert")
  local first_tab = vim.api.nvim_get_current_tabpage()
  local claude = term.get_active_terminal_bufnr()
  vim.cmd("tabnew")
  local other_tab = vim.api.nvim_get_current_tabpage()
  local copy = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(copy, claude)
  vim.api.nvim_set_current_tabpage(first_tab)
  term.simple_toggle() -- hides the window of the first tab
  term = lib.reload(setup)
  term.open()
  lib.settle()
  lib.step(
    string.format(
      "hidden in the first tab, a copy in another, a reload, then open in the first tab: Claude windows in the first tab %d, in the other tab %d, you are in the %s tab",
      windows_in(first_tab, claude),
      windows_in(other_tab, claude),
      vim.api.nvim_get_current_tabpage() == first_tab and "first" or "other"
    ),
    windows_in(first_tab, claude) ~= 1
      or windows_in(other_tab, claude) ~= 1
      or vim.api.nvim_get_current_tabpage() ~= first_tab
  )
end)
lib.finish()
