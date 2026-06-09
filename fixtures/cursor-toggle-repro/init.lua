-- Minimal repro config for issue #240 / #183 — the "climbing cursor" bug.
--
-- Symptom: with the Snacks terminal provider (LazyVim's default), hiding and then
-- re-showing the Claude side panel leaves the terminal cursor one row ABOVE
-- Claude's "❯" input prompt, so typed text lands on the wrong line and the box
-- corrupts. (#183, on a float, reports the drift accumulating per toggle.)
--   #240: vertical split panel.   #183: floating window.   Same root cause.
--
-- This fixture deliberately avoids a plugin manager so it is fast, offline, and
-- easy to reason about (mirrors fixtures/repro). It loads the local
-- claudecode.nvim checkout that owns the fixture and an already-installed
-- snacks.nvim, both via runtimepath.
--
-- Usage (from repo root):
--   source fixtures/nvim-aliases.sh
--   vv cursor-toggle-repro
-- Then: <leader>ac toggles the Claude terminal. Toggle it off, then on, and
-- watch the `>` input prompt climb up one row each cycle.
--
-- Env knobs:
--   CURSOR_REPRO_CMD       command to run in the terminal (default: "claude").
--                          Point at fixtures/cursor-toggle-repro/box.py to get a
--                          deterministic, auth-free synthetic Claude-style TUI.
--   CURSOR_REPRO_POSITION  "right" (default, split = #240) or "float" (= #183).
--   CURSOR_REPRO_SNACKS_DIR override path to a snacks.nvim checkout.

local config_dir = vim.fn.stdpath("config")
local repo_root = vim.fn.fnamemodify(vim.env.XDG_CONFIG_HOME or config_dir, ":h")
vim.opt.rtp:prepend(repo_root)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Quieter, more deterministic editor for reproduction.
vim.o.swapfile = false
vim.o.shada = ""
vim.o.number = true
vim.o.laststatus = 2
vim.o.cmdheight = 1

-- Locate an installed snacks.nvim and put it on the runtimepath.
local function find_snacks()
  -- Build the list with table.insert: an explicit nil first element would make
  -- ipairs() stop immediately (it terminates at the first nil index).
  local candidates = {}
  if vim.env.CURSOR_REPRO_SNACKS_DIR and vim.env.CURSOR_REPRO_SNACKS_DIR ~= "" then
    table.insert(candidates, vim.env.CURSOR_REPRO_SNACKS_DIR)
  end
  table.insert(candidates, vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
  table.insert(candidates, vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim"))
  table.insert(candidates, vim.fn.expand("~/.local/share/nvim/site/pack/*/start/snacks.nvim"))
  for _, path in ipairs(candidates) do
    if path and path ~= "" then
      for _, hit in ipairs(vim.fn.glob(path, true, true)) do
        if vim.fn.isdirectory(hit .. "/lua/snacks") == 1 then
          return hit
        end
      end
    end
  end
  -- Last resort: clone into this fixture's data dir (one-time, needs network).
  local dest = vim.fn.stdpath("data") .. "/snacks.nvim"
  if vim.fn.isdirectory(dest .. "/lua/snacks") == 0 then
    vim.notify("cursor-toggle-repro: cloning snacks.nvim (one-time)...", vim.log.levels.INFO)
    vim.fn.system({ "git", "clone", "--filter=blob:none", "https://github.com/folke/snacks.nvim.git", dest })
  end
  return dest
end

local snacks_dir = find_snacks()
vim.opt.rtp:prepend(snacks_dir)

local ok_snacks = pcall(function()
  require("snacks").setup({})
end)
if not (ok_snacks and _G.Snacks and _G.Snacks.terminal) then
  vim.notify("cursor-toggle-repro: snacks.terminal unavailable at " .. snacks_dir, vim.log.levels.ERROR)
end

local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

-- Build snacks_win_opts depending on the requested layout (split vs float).
local position = vim.env.CURSOR_REPRO_POSITION or "right"
local snacks_win_opts = {}
if position == "float" then
  snacks_win_opts = { position = "float", width = 0.9, height = 0.9 }
end
-- CURSOR_REPRO_BORDER: override the Snacks window border (default "top" adds a
-- 1-row top border). Set to "none" to test whether the border is what tips the
-- split into the climbing-cursor drift.
if vim.env.CURSOR_REPRO_BORDER and vim.env.CURSOR_REPRO_BORDER ~= "" then
  snacks_win_opts.border = vim.env.CURSOR_REPRO_BORDER
end

claudecode.setup({
  auto_start = false, -- start the server explicitly so toggles are deterministic
  -- Keep the screen clean for automated driving; bump to "debug" for triage.
  log_level = vim.env.CURSOR_REPRO_LOG_LEVEL or "warn",
  -- Honour an explicit synthetic command, else fall back to the real `claude`.
  terminal_cmd = vim.env.CURSOR_REPRO_CMD, -- nil => provider default ("claude")
  terminal = {
    -- LazyVim's effective provider is "snacks"; override to "native" with
    -- CURSOR_REPRO_PROVIDER to compare providers when localizing the bug.
    provider = vim.env.CURSOR_REPRO_PROVIDER or "snacks",
    auto_close = false,
    snacks_win_opts = snacks_win_opts,
  },
  diff_opts = {
    layout = "vertical",
  },
})

local function ensure_started()
  local ok_start, started_or_err, port_or_err = pcall(function()
    return claudecode.start(false)
  end)
  if not ok_start then
    vim.notify("ClaudeCode start crashed: " .. tostring(started_or_err), vim.log.levels.ERROR)
    return false
  end
  if started_or_err then
    return true
  end
  if port_or_err == "Already running" then
    return true
  end
  vim.notify("ClaudeCode failed to start: " .. tostring(port_or_err), vim.log.levels.ERROR)
  return false
end

local terminal = require("claudecode.terminal")

-- The repro toggle: simple_toggle (== :ClaudeCode), show/hide regardless of focus.
vim.keymap.set({ "n", "t" }, "<leader>ac", function()
  if ensure_started() then
    terminal.simple_toggle({}, nil)
  end
end, { desc = "Toggle Claude (simple_toggle)" })

vim.keymap.set({ "n", "t" }, "<leader>af", function()
  if ensure_started() then
    terminal.focus_toggle({}, nil)
  end
end, { desc = "Focus Claude (focus_toggle)" })

-- Make it easy to escape the terminal to drive ex-commands.
vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })

-- EXPERIMENT: native-style hide/show of the (snacks-created) Claude buffer.
-- Open once with <leader>ac (snacks), then toggle with <leader>an. This closes
-- the window with nvim_win_close on hide and recreates a plain vsplit +
-- nvim_win_set_buf on show -- exactly what the native provider does -- but on
-- the SAME terminal buffer snacks spawned. If this does not drift, the cure for
-- the split case is native-style window management, not snacks' open_win.
vim.keymap.set({ "n", "t" }, "<leader>an", function()
  local bufnr = terminal.get_active_terminal_bufnr()
  if not bufnr then
    vim.notify("no claude terminal buffer; open it with <leader>ac first", vim.log.levels.WARN)
    return
  end
  local win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      win = w
      break
    end
  end
  if win then
    vim.api.nvim_win_close(win, false) -- native hide: drop the window, keep the buffer+job
  else
    local width = math.floor(vim.o.columns * 0.30)
    vim.cmd("botright " .. width .. "vsplit")
    local nw = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(nw, bufnr)
    vim.cmd("startinsert")
  end
end, { desc = "native-style toggle of claude buffer" })

-- EXPERIMENT: config-hide toggle (nvim_win_set_config{hide}) of the Claude
-- window. Keeps the window object alive, so the cursor anchor is preserved.
-- Visually hides FLOATS (use CURSOR_REPRO_POSITION=float); a split stays visible.
vim.keymap.set({ "n", "t" }, "<leader>ah", function()
  local bufnr = terminal.get_active_terminal_bufnr()
  if not bufnr then
    return
  end
  local win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      win = w
      break
    end
  end
  if not win then
    vim.notify("no claude window", vim.log.levels.WARN)
    return
  end
  if vim.api.nvim_win_get_config(win).hide == true then
    vim.api.nvim_win_set_config(win, { hide = false })
    vim.api.nvim_set_current_win(win)
    vim.cmd("startinsert")
  else
    vim.api.nvim_win_set_config(win, { hide = true })
    if vim.api.nvim_get_current_win() == win then
      pcall(vim.cmd, "wincmd p")
    end
  end
end, { desc = "config-hide toggle of claude window" })

-- EXPERIMENT: after a normal (drifted) snacks show, re-set the same buffer into
-- its existing window. If this re-anchors (delta back to 0) it is a minimal,
-- snacks-window-PRESERVING fix (keeps snacks' keymaps/styling, unlike a full
-- native recreate). Repro drift with <leader>ac, then press <leader>ar.
vim.keymap.set({ "n", "t" }, "<leader>ar", function()
  local bufnr = terminal.get_active_terminal_bufnr()
  if not bufnr then
    return
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      vim.api.nvim_win_set_buf(w, bufnr) -- re-set same buffer; may re-anchor the view
      return
    end
  end
end, { desc = "re-set claude buffer into its window" })

-- Measurement helper: dump the Claude terminal window's geometry so the climb
-- can be quantified without screen-scraping. Prints cursor row, window topline
-- (first visible buffer line), window height, and total buffer lines.
vim.api.nvim_create_user_command("ReproCursorInfo", function()
  local bufnr = terminal.get_active_terminal_bufnr()
  if not bufnr then
    vim.notify("ReproCursorInfo: no active claude terminal buffer", vim.log.levels.WARN)
    return
  end
  local win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      win = w
      break
    end
  end
  if not win then
    vim.notify("ReproCursorInfo: terminal buffer not visible in any window", vim.log.levels.WARN)
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local topline = vim.fn.line("w0", win)
  local botline = vim.fn.line("w$", win)
  local height = vim.api.nvim_win_get_height(win)
  local total = vim.api.nvim_buf_line_count(bufnr)
  -- cursor_within_win = how many rows down from the top of the window the cursor
  -- sits. This is the number that climbs as you toggle.
  local within = cursor[1] - topline + 1
  local line = string.format(
    "cursor_line=%d cursor_col=%d topline=%d botline=%d win_height=%d buf_lines=%d cursor_within_win=%d",
    cursor[1],
    cursor[2],
    topline,
    botline,
    height,
    total,
    within
  )
  -- Append to a log file so automated drivers can read it without screen-scraping
  -- and without tripping Neovim's hit-enter prompt.
  local log_path = vim.env.CURSOR_REPRO_LOG or (vim.fn.stdpath("cache") .. "/cursor-toggle-repro.log")
  local fh = io.open(log_path, "a")
  if fh then
    fh:write(line .. "\n")
    fh:close()
  end
  vim.api.nvim_echo({ { "ReproCursorInfo: " .. line } }, false, {})
end, { desc = "Dump claude terminal window geometry" })

vim.keymap.set("n", "<leader>ai", "<cmd>ReproCursorInfo<cr>", { desc = "Claude terminal geometry" })

-- Dump the Claude terminal window's options that could explain a height/anchor
-- difference between providers (winbar, statusline, border, height).
vim.api.nvim_create_user_command("ReproWinDiag", function()
  local bufnr = terminal.get_active_terminal_bufnr()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if bufnr and vim.api.nvim_win_get_buf(w) == bufnr then
      local cfg = vim.api.nvim_win_get_config(w)
      table.insert(
        out,
        string.format(
          "termwin=%d height=%d width=%d winbar=[%s] relative=[%s] zindex=%s",
          w,
          vim.api.nvim_win_get_height(w),
          vim.api.nvim_win_get_width(w),
          tostring(vim.wo[w].winbar),
          tostring(cfg.relative),
          tostring(cfg.zindex)
        )
      )
    end
  end
  local log_path = vim.env.CURSOR_REPRO_LOG or (vim.fn.stdpath("cache") .. "/cursor-toggle-repro.log")
  local fh = io.open(log_path, "a")
  if fh then
    fh:write("WINDIAG " .. (table.concat(out, " | ") == "" and "no termwin" or table.concat(out, " | ")) .. "\n")
    fh:close()
  end
end, { desc = "Dump claude terminal window options" })

-- CANDIDATE FIX PROBE (#183): toggle the Claude FLOAT by HIDING the window via
-- nvim_win_set_config{hide=true/false} instead of closing+recreating it (what
-- Snacks does). This keeps the window OBJECT (and thus libvterm's grid + cursor
-- anchor) alive across the toggle, which the triage predicts keeps Claude's
-- focus-in repaint aligned (delta stays 0). Bound to <leader>ah; the float-fix
-- driver uses this instead of <leader>ac.
--
-- We cache the window id because a config-hidden window is still VALID
-- (nvim_win_is_valid==true) but may not be returned by nvim_list_wins(); caching
-- lets us un-hide the exact same window object we hid.
local cached_claude_win = nil
local function locate_claude_float()
  local bufnr = terminal.get_active_terminal_bufnr()
  if not bufnr then
    return nil
  end
  if cached_claude_win and vim.api.nvim_win_is_valid(cached_claude_win) then
    return cached_claude_win
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == bufnr then
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg and cfg.relative and cfg.relative ~= "" then
        cached_claude_win = w
        return w
      end
    end
  end
  return nil
end

vim.api.nvim_create_user_command("ReproConfigHideToggle", function()
  if not ensure_started() then
    return
  end
  local bufnr = terminal.get_active_terminal_bufnr()
  -- Nothing open yet: let Snacks create+show the float the first time.
  if not bufnr then
    terminal.simple_toggle({}, nil)
    return
  end
  local w = locate_claude_float()
  if not (w and vim.api.nvim_win_is_valid(w)) then
    -- Fall back to Snacks show if we somehow lost the window handle.
    terminal.simple_toggle({}, nil)
    return
  end
  local cfg = vim.api.nvim_win_get_config(w)
  if cfg.hide then
    -- Currently hidden -> show + refocus + insert (mirror what a real toggle does).
    vim.api.nvim_win_set_config(w, { hide = false })
    pcall(vim.api.nvim_set_current_win, w)
    vim.cmd("startinsert")
  else
    -- Currently visible -> hide WITHOUT destroying the window.
    vim.api.nvim_win_set_config(w, { hide = true })
  end
end, { desc = "Toggle Claude float via win_set_config{hide} (candidate #183 fix)" })

vim.keymap.set(
  { "n", "t" },
  "<leader>ah",
  "<cmd>ReproConfigHideToggle<cr>",
  { desc = "Config-hide toggle (fix probe)" }
)
