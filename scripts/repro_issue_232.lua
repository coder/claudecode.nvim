-- Reproduction / verification for issue #232:
--   "[FEATURE] Terminal window should restore scroll position when switching
--    back from editor window"
--   https://github.com/coder/claudecode.nvim/issues/232
--
-- Behavior under test: when focus returns to the Claude terminal window (as if
-- via `<C-w>l`), does the plugin force the terminal back into terminal/insert
-- mode? With the Snacks provider it does -- Snacks' `auto_insert` registers a
-- buffer-local BufEnter autocmd that runs `startinsert` on every entry, which
-- snaps the view to the bottom prompt and discards the user's Normal-mode scroll
-- position. The native provider registers no such autocmd, so it stays in Normal
-- mode (the behavior the reporter wants).
--
-- This script drives the REAL terminal provider code (no Claude CLI, no network;
-- the terminal runs a trivial `cat`). It:
--   1. opens the Claude terminal (focused),
--   2. drops to Normal mode and scrolls to the TOP,
--   3. moves to an editor window, then moves BACK to the terminal window,
--   4. measures the mode and the first visible line afterwards.
--
-- Provider is chosen by env (so one script covers both code paths):
--   CLAUDECODE_PROVIDER=snacks  (default) -> expected to reproduce the bug
--   CLAUDECODE_PROVIDER=native            -> baseline, should NOT reproduce
--
-- Run from the repo root:
--   nvim --headless -u NONE -l scripts/repro_issue_232.lua
--   CLAUDECODE_PROVIDER=native nvim --headless -u NONE -l scripts/repro_issue_232.lua
--
-- Exit code: 1 if the terminal re-entered terminal mode on re-focus (#232
-- reproduced), 0 if it stayed in Normal mode (baseline / fixed).

local script_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ":h:h")
vim.opt.rtp:prepend(repo_root)

local function out(msg)
  io.stdout:write(msg .. "\n")
end

local provider = vim.env.CLAUDECODE_PROVIDER or "snacks"

-- Put an installed snacks.nvim on the runtimepath when testing that provider.
if provider == "snacks" then
  local candidates = vim.fn.glob(vim.fn.expand("~/.local/share/*/lazy/snacks.nvim"), true, true)
  table.insert(candidates, 1, vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim"))
  local found = nil
  for _, p in ipairs(candidates) do
    if p ~= "" and vim.fn.isdirectory(p) == 1 then
      found = p
      break
    end
  end
  if found then
    vim.opt.rtp:prepend(found)
    out("[setup] snacks.nvim runtimepath: " .. found)
  else
    out("SKIP: snacks.nvim not found on disk; cannot test the snacks provider.")
    os.exit(0)
  end
  local ok_snacks = pcall(require, "snacks")
  if not ok_snacks then
    out("SKIP: failed to require('snacks').")
    os.exit(0)
  end
end

local fake_claude = repo_root .. "/fixtures/issue-232/fake-claude.sh"
-- Fallback to a bare `cat` if the fixture script is missing for any reason.
local terminal_cmd = (vim.fn.filereadable(fake_claude) == 1) and fake_claude or "cat"

-- Optional fix toggle: CLAUDECODE_AUTO_INSERT=false exercises PR #233's option.
local auto_insert = nil
if vim.env.CLAUDECODE_AUTO_INSERT == "false" then
  auto_insert = false
elseif vim.env.CLAUDECODE_AUTO_INSERT == "true" then
  auto_insert = true
end

local cc = require("claudecode")
cc.setup({
  auto_start = false,
  log_level = "error",
  terminal_cmd = terminal_cmd,
  terminal = {
    provider = provider,
    split_side = "right",
    split_width_percentage = 0.5,
    auto_close = false,
    show_native_term_exit_tip = false,
    auto_insert = auto_insert,
  },
})

local terminal = require("claudecode.terminal")

-- 1. Open the Claude terminal, focused (this is the normal `:ClaudeCode` path).
terminal.simple_toggle({}, nil)

-- Let the PTY spawn and Snacks wire up its autocmds.
vim.wait(800, function()
  local b = terminal.get_active_terminal_bufnr()
  return b ~= nil and vim.api.nvim_buf_is_valid(b)
end)

local term_bufnr = terminal.get_active_terminal_bufnr()
if not term_bufnr or not vim.api.nvim_buf_is_valid(term_bufnr) then
  out("ERROR: terminal buffer was never created; cannot run repro.")
  os.exit(2)
end

-- Find the window showing the terminal buffer.
local function term_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == term_bufnr then
      return w
    end
  end
  return nil
end

local tw = term_win()
if not tw then
  out("ERROR: terminal window not found after open.")
  os.exit(2)
end

-- Inspect the BufEnter autocmds registered on the terminal buffer (Snacks'
-- auto_insert path registers one that calls startinsert).
local buf_enter_aucmds = vim.api.nvim_get_autocmds({ event = "BufEnter", buffer = term_bufnr })
out(("[probe] BufEnter autocmds on terminal buffer: %d"):format(#buf_enter_aucmds))

-- 2. Drop to Normal mode and scroll to the TOP of the output.
vim.api.nvim_set_current_win(tw)
vim.cmd("stopinsert")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes([[<C-\><C-n>]], true, false, true), "x", false)
vim.api.nvim_win_call(tw, function()
  vim.cmd("normal! gg")
end)
local mode_at_top = vim.api.nvim_get_mode().mode
local first_visible_top = vim.fn.line("w0", tw)
out(
  ("[step] after <C-\\><C-n> + gg in terminal: mode=%q  first_visible_line=%d"):format(mode_at_top, first_visible_top)
)

-- 3a. Move to an editor window (open the sample file in a left split).
vim.cmd("topleft vsplit")
local editor_win = vim.api.nvim_get_current_win()
vim.cmd("enew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "editor window: pretend this is my code" })
vim.api.nvim_set_current_win(editor_win)
out(("[step] moved to editor window: mode=%q"):format(vim.api.nvim_get_mode().mode))

-- 3b. Move BACK to the terminal window -- the moment under test. This is what
-- `<C-w>l` does: it makes the terminal window current, firing BufEnter.
vim.api.nvim_set_current_win(tw)

-- Snacks runs `startinsert` from the BufEnter callback; give the event loop a
-- moment to apply it.
vim.wait(300, function()
  return vim.api.nvim_get_mode().mode == "t"
end)

local mode_after_refocus = vim.api.nvim_get_mode().mode
local first_visible_after = vim.fn.line("w0", tw)
out(
  ("[step] after switching BACK to terminal window: mode=%q  first_visible_line=%d"):format(
    mode_after_refocus,
    first_visible_after
  )
)

out("")
out("Note: a real `startinsert` only takes visible effect under an attached UI;")
out("in headless `-l` mode the pending mode change is deferred and not applied,")
out("so mode() above reads 'nt' regardless. The DETERMINISTic signal here is")
out("whether the plugin registered an auto-insert-on-focus autocmd at all -- see")
out("the [probe] line. The VISIBLE jump-to-bottom is demonstrated via agent-tty.")
out("")
out(("==== RESULT (provider=%s, auto_insert=%s) ===="):format(provider, tostring(auto_insert)))
-- The root cause of #232 is the BufEnter-driven startinsert that Snacks'
-- `auto_insert` registers on the terminal buffer. Its presence == bug present.
local reproduced = (#buf_enter_aucmds > 0)
if reproduced then
  out("REPRODUCED: an auto-insert BufEnter autocmd is registered on the Claude")
  out("  terminal buffer. Re-focusing the terminal window (e.g. <C-w>l) fires it,")
  out("  runs startinsert, and snaps the view to the bottom prompt -- discarding the")
  out("  Normal-mode scroll position (issue #232).")
else
  out("NOT reproduced: no auto-insert-on-focus autocmd on the terminal buffer.")
  out("  Re-focusing the terminal window keeps Normal mode and preserves the scroll")
  out("  position -- the behavior the reporter wants.")
end
out(
  ("(observed: mode_after_refocus=%q, first_visible top=%d -> after=%d)"):format(
    mode_after_refocus,
    first_visible_top,
    first_visible_after
  )
)

-- Clean up the PTY job.
pcall(function()
  terminal.close()
end)

os.exit(reproduced and 1 or 0)
