-- Reproduction / verification for issue #246:
--   "Single-line visual selections are not pushed to Claude."
--   https://github.com/coder/claudecode.nvim/issues/246
--
-- Root cause (selection.lua), all timing/extraction, none Claude-CLI side:
--   1. 100ms debounce race: a visual selection made and released faster than
--      M.state.debounce_ms was never captured (update_selection only runs in the
--      visual branch if its debounced callback fires while still in visual mode).
--   2. Demotion-to-empty: after leaving visual mode (with an EXTERNAL Claude, where
--      there is no in-Neovim terminal to "switch to"), the selection was wiped to an
--      empty cursor ~debounce+demotion ms later.
--   3. get_effective_visual_mode() trusted vim.fn.visualmode() (the LAST COMPLETED
--      visual mode) over the live mode, so a single-line linewise `V` right after a
--      charwise selection was extracted charwise -> 1 char (or empty on an empty line).
--
-- The fix: flush the selection synchronously on visual-mode exit (from the '<,'>
-- marks), demote only after the cursor actually moves, and prefer the live mode in
-- get_effective_visual_mode().
--
-- This script drives the REAL selection.lua through the actual autocmd path
-- (ModeChanged -> flush) and real uv timers, with a mock server capturing broadcasts.
-- No WebSocket/Claude CLI needed.
--
-- Run from the repo root:
--   nvim --headless -u NONE -l scripts/repro_issue_246.lua
--
-- Exit code: 0 if every check passes (fixed), 1 if any check fails (#246 reproduced).

local script_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ":h:h")
vim.opt.rtp:prepend(repo_root)

local function out(msg)
  io.stdout:write(msg .. "\n")
end

local selection = require("claudecode.selection")

local broadcasts = {}
local mock_server = {
  broadcast = function(_, params)
    table.insert(broadcasts, vim.deepcopy(params))
    return true
  end,
}

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, repo_root .. "/__issue_246_sample__.txt")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "alpha beta gamma",
  "delta epsilon zeta",
  "eta theta iota",
})
vim.api.nvim_set_current_buf(buf)
selection.enable(mock_server, 50)

local function t(k)
  return vim.api.nvim_replace_termcodes(k, true, false, true)
end

local function reset()
  vim.api.nvim_feedkeys(t("<Esc>"), "x", false)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  selection.state.latest_selection = nil
  selection.state.last_active_visual_selection = nil
  selection.state.cursor_at_flush = nil
  selection.state.visual_entry = nil
  selection._cancel_debounce_timer()
  selection._cancel_demotion_timer()
  broadcasts = {}
end

local function nonempty_broadcasts()
  local n = 0
  for _, b in ipairs(broadcasts) do
    if not b.selection.isEmpty then
      n = n + 1
    end
  end
  return n
end

local function latest_text()
  local s = selection.state.latest_selection
  return s and s.text or nil
end

local function latest_is_empty()
  local s = selection.state.latest_selection
  return s == nil or s.selection.isEmpty
end

local all_ok = true
local function check(name, ok)
  if not ok then
    all_ok = false
  end
  out(("  [%s] %s"):format(ok and "PASS" or "FAIL", name))
end

out("== issue #246 reproduction / verification ==")

-- 1. THE BUG: a fast single-line viw + Esc must reach Claude (one non-empty frame) and persist.
reset()
vim.api.nvim_feedkeys(t("viw"), "x", false)
vim.api.nvim_feedkeys(t("<Esc>"), "x", false)
vim.wait(300)
out("\n[1] fast viw + Esc, cursor left still")
check("a non-empty selection was broadcast", nonempty_broadcasts() >= 1)
check("latest selection is 'alpha'", latest_text() == "alpha")
check("selection persists (not demoted)", not latest_is_empty())

-- 2. After a real cursor move, the held selection is demoted to an empty cursor.
reset()
vim.api.nvim_feedkeys(t("viw"), "x", false)
vim.api.nvim_feedkeys(t("<Esc>"), "x", false)
vim.wait(20)
vim.api.nvim_feedkeys(t("l"), "x", false)
vim.wait(300)
out("\n[2] fast viw + Esc, then move the cursor")
check("selection demoted to empty after move", latest_is_empty())

-- 3. A lingered selection is sent exactly once (flush dedups against the in-visual debounce).
reset()
vim.api.nvim_feedkeys(t("viw"), "x", false)
vim.wait(150)
vim.api.nvim_feedkeys(t("<Esc>"), "x", false)
vim.wait(250)
out("\n[3] lingered viw then Esc (no duplicate frame)")
check("exactly one non-empty broadcast", nonempty_broadcasts() == 1)
check("latest still 'alpha'", latest_text() == "alpha")

-- 4. Stale-visualmode fix: a single-line linewise V after a charwise selection sends the whole line.
reset()
vim.api.nvim_feedkeys(t("viw"), "x", false) -- prime visualmode() = 'v'
vim.api.nvim_feedkeys(t("<Esc>"), "x", false)
vim.wait(30)
broadcasts = {}
selection.state.latest_selection = nil
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys(t("V"), "x", false)
vim.wait(150)
out("\n[4] charwise viw THEN single-line linewise V")
check("V sends the whole line, not 1 char", latest_text() == "delta epsilon zeta")

-- 5. Fast multi-line Vjj + Esc reaches Claude too.
reset()
vim.api.nvim_feedkeys(t("Vjj"), "x", false)
vim.api.nvim_feedkeys(t("<Esc>"), "x", false)
vim.wait(300)
out("\n[5] fast Vjj + Esc (multi-line)")
check("a non-empty selection was broadcast", nonempty_broadcasts() >= 1)
check(
  "selection spans three lines",
  (selection.state.latest_selection or {}).selection ~= nil
    and selection.state.latest_selection.selection["end"].line == 2
)

-- 6. An operator that consumes the selection (viwd) must NOT broadcast phantom post-edit text.
reset()
vim.api.nvim_feedkeys(t("viwd"), "x", false) -- delete inner word: mutates buffer, exits visual
vim.wait(300)
out("\n[6] viwd (operator consumes/mutates the selection)")
check("no phantom non-empty broadcast after a mutating operator", nonempty_broadcasts() == 0)

out("\n== verdict ==")
if all_ok then
  out("FIXED: single- and multi-line selections reach Claude on visual exit and persist until the cursor moves.")
else
  out("BUG REPRODUCED: at least one selection was not pushed (issue #246).")
end

io.stdout:flush()
vim.cmd("cquit " .. (all_ok and 0 or 1))
