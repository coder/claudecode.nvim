-- OpenShowsLiveClaude: after a reload, an adopted snacks float that an older version started must come back with the
-- window options of the config. An older version stored no window options in a buffer variable, so an entry without a
-- config (get_active_terminal_bufnr, which selection tracking calls) can wrap the terminal first, and the wrapper then
-- had Snacks' default float (72x24 or 108x40 and a split winbar) when the float was closed and opened again.
-- Path (a float): you open Claude; the replay deletes the buffer variables, as an older version leaves them; the plugin
-- reloads; the first entry is get_active_terminal_bufnr (or an open, or a toggle); you :close the float; you open Claude
-- again. The float must have the size and the empty winbar that it had at the first start.
-- Main has no bug here (it asks Snacks for the original instance). The replay guards the wrapper that #482 builds: a BUG
-- line means an older terminal comes back with the defaults of Snacks.
local lib = dofile(os.getenv("REPLAY_LIB"))
vim.o.termguicolors = true

local function float_size(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  if not win then
    return "no window"
  end
  local cfg = vim.api.nvim_win_get_config(win)
  return string.format(
    "%s %dx%d winbar=%q",
    cfg.relative ~= "" and "float" or "split",
    cfg.width,
    cfg.height,
    vim.wo[win].winbar
  )
end

local function setup()
  local term = require("claudecode.terminal")
  term.setup({
    provider = "snacks",
    auto_close = true,
    snacks_win_opts = { position = "float", width = 0.6, height = 0.5 },
  }, "sh -c 'sleep 60'")
  return term
end

for _, first_entry in ipairs({ "get_active_terminal_bufnr", "open", "simple_toggle" }) do
  lib.attempt("first entry " .. first_entry, function()
    local term = lib.reload(setup)
    term.open()
    lib.settle()
    vim.cmd("stopinsert")
    local claude = term.get_active_terminal_bufnr()
    local started = float_size(claude)
    -- What an older version leaves: the mark only.
    vim.b[claude].claudecode_snacks_auto_close = nil
    vim.b[claude].claudecode_snacks_window = nil
    vim.b[claude].claudecode_snacks_backdrop = nil
    term = lib.reload(setup)
    if first_entry == "simple_toggle" then
      term.simple_toggle() -- adopts and hides
      term.simple_toggle()
      lib.settle()
    else
      term[first_entry]()
    end
    lib.settle()
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(claude)[1])
    vim.cmd("close")
    lib.settle()
    term.open()
    lib.settle()
    local after = float_size(claude)
    lib.step(
      string.format(
        "first entry %s, then :close and open: started as %s, comes back as %s, %d Claude running",
        first_entry,
        started,
        after,
        #lib.running()
      ),
      after ~= started or #lib.running() ~= 1
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
