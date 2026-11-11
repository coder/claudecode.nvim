-- HideKeepsClaude: after a reload, the hide of an adopted snacks float must hide the backdrop that the float has now.
-- Snacks makes a new backdrop each time it re-creates a float. The provider names the backdrop in a buffer variable, so
-- that the next copy of the module can find it after a reload. A variable that only the first start wrote named a backdrop
-- that was gone, so after "float, reload, :close, open, reload" a hide left the new backdrop on the screen, and a show put
-- the float on top of it again.
-- Path (a float, termguicolors on, so that Snacks makes a backdrop): you open Claude; the plugin reloads; you :close the float
-- and open Claude again (Snacks re-creates it with a new backdrop); the plugin reloads (none, once, twice); a toggle hides
-- the float; a toggle shows it; a toggle hides it. A hidden float must leave no backdrop shown, and a shown float must have
-- exactly one.
-- Main has no bug here. The replay guards the buffer variable that #482 writes: a BUG line means a backdrop outlives its float.
local lib = dofile(os.getenv("REPLAY_LIB"))
vim.o.termguicolors = true

-- The float of the terminal and the number of backdrops that are shown.
local function state(buf)
  local backdrops, float = 0, "no window"
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "snacks_win_backdrop" and not cfg.hide then
      backdrops = backdrops + 1
    end
    if vim.api.nvim_win_get_buf(win) == buf then
      float = cfg.hide and "float hidden" or "float shown"
    end
  end
  return float, backdrops
end

for _, reloads_after in ipairs({ 0, 1, 2 }) do
  lib.attempt(string.format("%d reload(s) after the re-create", reloads_after), function()
    local function setup()
      local term = require("claudecode.terminal")
      term.setup({
        provider = "snacks",
        auto_close = true,
        snacks_win_opts = { position = "float", width = 0.6, height = 0.5 },
      }, "sh -c 'sleep 60'")
      return term
    end
    local term = lib.reload(setup)
    term.open()
    lib.settle()
    vim.cmd("stopinsert")
    local claude = term.get_active_terminal_bufnr()
    term = lib.reload(setup)
    term.get_active_terminal_bufnr()
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(claude)[1])
    vim.cmd("close")
    lib.settle()
    term.open()
    lib.settle()
    for _ = 1, reloads_after do
      term = lib.reload(setup)
    end
    for number, what in ipairs({ "hide", "show", "hide" }) do
      term.simple_toggle()
      lib.settle()
      local float, backdrops = state(claude)
      lib.step(
        string.format(
          "%d reload(s) after the float was re-created, toggle %d (%s): %s, %d backdrop shown",
          reloads_after,
          number,
          what,
          float,
          backdrops
        ),
        (float == "float hidden" and backdrops > 0) or (float == "float shown" and backdrops ~= 1)
      )
    end
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
