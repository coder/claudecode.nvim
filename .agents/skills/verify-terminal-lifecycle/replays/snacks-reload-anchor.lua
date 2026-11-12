-- OpenShowsLiveClaude: after a reload, an adopted snacks float that is relative to a window must come back anchored to that
-- window. Snacks takes the window that is current when it creates an instance, when the options name no anchor, and the
-- stored window options had dropped the anchor, so the float that the provider re-created was positioned and sized
-- relative to whichever window was current at the adoption.
-- Path: two windows; you open Claude in a float with `relative = "win"` and the left window as `win`; the plugin reloads;
-- the other window is current when an entry adopts it; you :close the float and open Claude again. The float must have the
-- size and the anchor that it had at the first start. When the anchor window has closed by then, the float is anchored to
-- the current window, as Snacks does for an option without an anchor.
-- Main has no bug here. The replay guards the wrapper that #482 builds: a BUG line means a float lost its anchor.
local lib = dofile(os.getenv("REPLAY_LIB"))

vim.cmd("vsplit")
local anchor = vim.api.nvim_get_current_win()
local other = vim.fn.win_getid(2)

local function setup()
  local term = require("claudecode.terminal")
  term.setup({
    provider = "snacks",
    auto_close = true,
    snacks_win_opts = {
      position = "float",
      relative = "win",
      win = anchor,
      width = 0.5,
      height = 0.5,
      row = 1,
      col = 1,
    },
  }, "sh -c 'sleep 60'")
  return term
end

local function describe(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  if not win then
    return "no window"
  end
  local cfg = vim.api.nvim_win_get_config(win)
  return string.format(
    "float %dx%d, relative %s, anchored to %s",
    cfg.width,
    cfg.height,
    cfg.relative,
    cfg.win == anchor and "the anchor" or (cfg.win == other and "the other window" or tostring(cfg.win))
  )
end

lib.attempt("a float relative to a window", function()
  local term = lib.reload(setup)
  vim.api.nvim_set_current_win(anchor)
  term.open()
  lib.settle()
  vim.cmd("stopinsert")
  local claude = term.get_active_terminal_bufnr()
  local started = describe(claude)
  term = lib.reload(setup)
  vim.api.nvim_set_current_win(other)
  term.get_active_terminal_bufnr() -- adopts while the other window is current
  vim.api.nvim_set_current_win(vim.fn.win_findbuf(claude)[1])
  vim.cmd("close")
  lib.settle()
  vim.api.nvim_set_current_win(other)
  term.open()
  lib.settle()
  local after = describe(claude)
  lib.step(
    string.format("first start: %s; after a reload, :close and open: %s", started, after),
    started ~= after or #lib.running() ~= 1
  )
end)
lib.finish()
