-- Fixture for issue #277:
--   "[BUG] closeAllDiffTabs closes all diff-mode windows, destroying unrelated
--    diffs (diffview.nvim)"
--   https://github.com/coder/claudecode.nvim/issues/277
--
-- Two defects under test:
--   1. tools/close_all_diff_tabs.lua closes EVERY `&diff` window (no ownership
--      check), so diffview.nvim / fugitive / native `:diffthis` layouts are
--      destroyed when the Claude CLI fires closeAllDiffTabs (it does so at the
--      start of a user turn whenever an IDE is connected).
--   2. find_main_editor_window (tools/open_file.lua and diff.lua) does not
--      exclude `&diff` windows, so openFile/openDiff target a diffview window
--      and :edit into it, corrupting the diff layout.
--
-- The fixture pulls in diffview.nvim (cloned on first run) and exposes a
-- window-state probe for scripted verification:
--   nvim --server <sock> --remote-expr 'v:lua.Repro277State()'
--
-- Usage (from repo root):
--   source fixtures/nvim-aliases.sh && vv issue-277
-- or scripted:
--   scripts/repro_issue_277.sh
--
-- Manual repro: open a file in a git repo with uncommitted changes,
-- :DiffviewOpen, connect claude (--ide), submit any prompt -> the side-by-side
-- diff windows close, only the Diffview file panel survives.

local config_dir = vim.fn.stdpath("config")
local repo_root = vim.fn.fnamemodify(config_dir, ":h:h")
vim.opt.rtp:prepend(repo_root)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- ---------------------------------------------------------------------------
-- diffview.nvim (cloned into stdpath("data") on first run; no plugin manager)
-- ---------------------------------------------------------------------------
local diffview_dir = vim.fn.stdpath("data") .. "/diffview.nvim"
if vim.fn.isdirectory(diffview_dir) == 0 then
  vim.notify("issue-277 fixture: cloning diffview.nvim ...")
  local out = vim.fn.system({
    "git",
    "clone",
    "--depth=1",
    "https://github.com/sindrets/diffview.nvim",
    diffview_dir,
  })
  assert(vim.v.shell_error == 0, "failed to clone diffview.nvim: " .. out)
end
vim.opt.rtp:prepend(diffview_dir)

local ok_dv, diffview = pcall(require, "diffview")
assert(ok_dv, "Failed to load diffview.nvim: " .. tostring(diffview))
diffview.setup({})

-- ---------------------------------------------------------------------------
-- claudecode.nvim (dev version from this repo)
-- ---------------------------------------------------------------------------
local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

claudecode.setup({
  auto_start = true, -- server + lock file immediately, so scripts can connect
  -- "warn", not "debug": multi-line debug echoes trip nvim's hit-enter prompt,
  -- which blocks --remote-expr probes in the scripted repro.
  log_level = "warn",
  terminal = {
    provider = "native",
    auto_close = false,
  },
})

vim.o.showtabline = 2
vim.o.laststatus = 2

-- ---------------------------------------------------------------------------
-- Window-state probe (for --remote-expr / on-screen verification)
-- ---------------------------------------------------------------------------

---Compact state of every window across all tabpages.
---@return string JSON: [{win,tab,name,buftype,filetype,diff}...]
function _G.Repro277State()
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    out[#out + 1] = {
      win = win,
      tab = vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(win)),
      name = vim.fn.fnamemodify(name, ":t") ~= "" and vim.fn.fnamemodify(name, ":~:.") or "[No Name]",
      buftype = vim.bo[buf].buftype,
      filetype = vim.bo[buf].filetype,
      diff = vim.wo[win].diff,
    }
  end
  return vim.json.encode(out)
end

---WebSocket endpoint of the running claudecode server ("port token", or "" if
---not started yet). Lets scripts connect without scanning ~/.claude/ide.
---@return string
function _G.Repro277Server()
  local cc = require("claudecode")
  if cc.state.port and cc.state.auth_token then
    return cc.state.port .. " " .. cc.state.auth_token
  end
  return ""
end

---Count of windows currently in diff mode (quick assertion helper).
---@return integer
function _G.Repro277DiffWinCount()
  local n = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[win].diff then
      n = n + 1
    end
  end
  return n
end

vim.api.nvim_create_user_command("ReproState", function()
  vim.notify(_G.Repro277State())
end, { desc = "Show issue-277 window state" })

-- Native (plugin-free) diff variant of the same bug: two `:diffsplit` windows.
vim.api.nvim_create_user_command("ReproNativeDiff", function(cmd_opts)
  local args = vim.split(cmd_opts.args, "%s+")
  assert(#args == 2, "usage: :ReproNativeDiff <file_a> <file_b>")
  vim.cmd("edit " .. vim.fn.fnameescape(args[1]))
  vim.cmd("vertical diffsplit " .. vim.fn.fnameescape(args[2]))
end, { nargs = "+", complete = "file", desc = "Open a native vimdiff of two files" })

vim.keymap.set("n", "<leader>aw", function()
  vim.notify(("diff windows: %d"):format(_G.Repro277DiffWinCount()))
end, { desc = "Show diff window count" })
