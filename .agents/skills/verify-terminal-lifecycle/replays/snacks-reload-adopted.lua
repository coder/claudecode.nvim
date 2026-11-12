-- OpenShowsLiveClaude: after a reload, an adopted snacks Claude must behave like one that the provider started itself. The
-- provider finds it by its mark and live job (not through Snacks.terminal.list()), wraps the buffer in a new Snacks window
-- (the terminal style, the options that the first start stored in b:claudecode_snacks_window), and takes the float's
-- backdrop again by the window id that the first start stored.
-- Path, for a split on the right and for a float (termguicolors on, so that Snacks makes a backdrop; another Snacks float
-- with its own backdrop is open too): you open Claude; the plugin reloads; a toggle adopts and hides it; a toggle shows it;
-- the window closes (:close in it); you open Claude; the plugin reloads again; :ClaudeCodeClose. Each shown window must be
-- a split or a float like the first one, with its size, its winbar, the snacks_win marker, its backdrop and its q key (it
-- hides the terminal). A hidden float leaves no backdrop of its own and leaves the other float's. No second Claude may
-- start, and the close must not report the stop as a failure.
-- Main has no bug here. The replay guards the adopted window that #482 builds: a BUG line means an adopted terminal differs
-- from one that the provider started itself.
local lib = dofile(os.getenv("REPLAY_LIB"))
vim.o.termguicolors = true
local failures = 0
vim.notify = function(message)
  if tostring(message):find("exited with code", 1, true) then
    failures = failures + 1
  end
end

-- The windows of the backdrops that are shown now.
local function backdrop_windows()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if
      vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "snacks_win_backdrop"
      and not vim.api.nvim_win_get_config(win).hide
    then
      table.insert(wins, win)
    end
  end
  return wins
end

-- Whether every window in `wins` is still a shown backdrop.
local function still_shown(wins)
  for _, win in ipairs(wins) do
    if not (vim.api.nvim_win_is_valid(win) and not vim.api.nvim_win_get_config(win).hide) then
      return false
    end
  end
  return true
end

-- The backdrops of the other Snacks float, which this replay opens after Claude's first start.
local others = {}

local function own_backdrops()
  local count = 0
  for _, win in ipairs(backdrop_windows()) do
    if not vim.tbl_contains(others, win) then
      count = count + 1
    end
  end
  return count
end

local function q_key(buf)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg("q", "n", false, true).desc
  end)
end

local function describe(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      local cfg = vim.api.nvim_win_get_config(win)
      return string.format(
        "%s %sx%s, winbar %q, snacks_win %s, q %s, %d backdrop",
        cfg.relative ~= "" and "float" or "split",
        cfg.width,
        cfg.height,
        vim.wo[win].winbar,
        tostring(vim.w[win].snacks_win ~= nil),
        tostring(q_key(buf)),
        own_backdrops()
      )
    end
  end
  return string.format("no window, q %s, %d backdrop", tostring(q_key(buf)), own_backdrops())
end

for _, position in ipairs({ "right", "float" }) do
  local function setup()
    local term = require("claudecode.terminal")
    term.setup({
      provider = "snacks",
      auto_close = true,
      snacks_win_opts = position == "float" and { position = "float", width = 0.6, height = 0.5 } or nil,
    }, "sh -c 'sleep 60'")
    return term
  end
  failures = 0
  others = {}
  local term = lib.reload(setup)
  term.open()
  lib.settle()
  vim.cmd("stopinsert")
  local claude = term.get_active_terminal_bufnr()
  local started = describe(claude)
  -- Another Snacks float, opened after Claude's. Its backdrop is one z-index below it, like the one of Claude's float,
  -- and it is listed before Claude's.
  local before = backdrop_windows()
  local other = position == "float"
      and require("snacks").win({ position = "float", width = 0.3, height = 0.3, enter = false, text = "another float" })
    or nil
  for _, win in ipairs(backdrop_windows()) do
    if not vim.tbl_contains(before, win) then
      table.insert(others, win)
    end
  end
  lib.step(string.format("%s: the first start shows %s", position, started))
  term = lib.reload(setup)
  term.simple_toggle()
  local hidden = describe(claude)
  lib.step(
    string.format("%s: after a reload, a toggle adopts and hides it: %s", position, hidden),
    own_backdrops() ~= 0 or not still_shown(others)
  )
  term.simple_toggle()
  lib.settle()
  local shown = describe(claude)
  lib.step(string.format("%s: a toggle shows it: %s", position, shown), shown ~= started)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == claude and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  term.open()
  lib.settle()
  local reopened = describe(claude)
  lib.step(
    string.format("%s: its window closed, then open: %s, %d Claude running", position, reopened, #lib.running()),
    reopened ~= started or #lib.running() ~= 1
  )
  term = lib.reload(setup)
  term.close()
  lib.wait(300)
  lib.step(
    string.format(
      "%s: reload, then close: %d Claude running, %d report of a failed exit, %d backdrop of Claude's left, the other float's still shown: %s",
      position,
      #lib.running(),
      failures,
      own_backdrops(),
      tostring(still_shown(others))
    ),
    #lib.running() ~= 0 or failures ~= 0 or own_backdrops() ~= 0 or not still_shown(others)
  )
  for _, buf in ipairs(lib.running()) do
    vim.b[buf].claudecode_snacks_terminal = nil
    pcall(vim.fn.jobstop, vim.bo[buf].channel)
  end
  if other then
    other:close()
  end
  lib.wait(300)
  vim.cmd("silent! %bwipeout!")
end
lib.finish()
