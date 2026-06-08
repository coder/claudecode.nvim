-- Reproduction / verification for issue #238:
--   "[BUG] Rejecting with `:q` does not work"
--   https://github.com/coder/claudecode.nvim/issues/238
--
-- The README documents two ways to reject a Claude diff: `:q` or <leader>ad
-- (:ClaudeCodeDiffDeny). The keymap works; `:q` does NOT.
--
-- Root cause: the proposed ("new") buffer is created with
--   vim.api.nvim_create_buf(false, true)   -- scratch => bufhidden = "hide"
-- and rejection is wired ONLY through buffer-destruction autocmds
--   BufDelete / BufUnload / BufWipeout  ->  _resolve_diff_as_rejected
-- Because bufhidden = "hide", running `:q` on the proposed window merely HIDES
-- the buffer (the window closes, the buffer stays loaded), so none of those
-- autocmds fire and the diff is never resolved as rejected. Claude is never
-- told DIFF_REJECTED and (with open_in_new_tab=true) the tab lingers.
--
-- This script drives the REAL diff.lua (the exact path the openDiff MCP tool
-- uses, M._setup_blocking_diff) and performs a genuine `:q` on the proposed
-- window — no WebSocket / Claude CLI needed. It both reproduces the bug (on
-- unfixed code) and verifies a fix.
--
-- Run from the repo root:
--   nvim --headless -u NONE -l scripts/repro_issue_238.lua
--
-- Exit code: 1 if the bug is reproduced (any scenario fails to reject on `:q`),
-- 0 if `:q` rejects in every scenario (fixed). The verdict is printed either way.

local script_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ":h:h")
vim.opt.rtp:prepend(repo_root)

local function out(msg)
  io.stdout:write(msg .. "\n")
end

local diff = require("claudecode.diff")

-- Match the reporter's terminal config (Claude runs in an external terminal, so
-- claudecode manages no terminal of its own). Best-effort: the bug does not
-- depend on the provider, but this keeps the repro faithful.
pcall(function()
  require("claudecode.terminal").setup({ provider = "none" }, nil)
end)

-- A single temp file under Neovim's own tempdir (auto-removed on exit, even on a
-- crash) -- so the gate never leaves an untracked file in the repo root.
local target_path = nil

---Write a real on-disk file so old_file_exists = true (editing an existing file).
---@return string path
local function make_target()
  target_path = target_path or vim.fn.tempname()
  vim.fn.writefile({ "line one", "line two", "line three", "line four", "line five" }, target_path)
  return target_path
end

---Reset to a single empty window/tab between scenarios.
local function reset_editor()
  pcall(function()
    diff._cleanup_all_active_diffs("repro reset")
  end)
  pcall(vim.cmd, "silent! tabonly")
  pcall(vim.cmd, "silent! only")
  pcall(vim.cmd, "silent! enew!")
end

---Open a diff for an existing file, then reject it with a genuine `:q`.
---@param open_in_new_tab boolean
---@return table report
local function run_scenario(open_in_new_tab)
  reset_editor()
  diff.setup({
    diff_opts = { layout = "vertical", open_in_new_tab = open_in_new_tab, keep_terminal_focus = false },
    terminal = { provider = "none" },
  })

  local target = make_target()
  local tab_name = ("REPRO238 target.txt (new_tab=%s)"):format(tostring(open_in_new_tab))

  -- The resolution callback is what the deferred-response system uses to send
  -- the result back to Claude. If `:q` rejects correctly it fires with
  -- DIFF_REJECTED; if the bug is present it never fires.
  local captured = nil
  diff._setup_blocking_diff({
    old_file_path = target,
    new_file_path = target,
    new_file_contents = "line one\nline two\nline three (EDITED BY CLAUDE)\nline four\nline five\n",
    tab_name = tab_name,
  }, function(result)
    captured = result
  end)

  -- Inspect the freshly-created diff state.
  local active = diff._get_active_diffs()
  local data = active[tab_name]
  assert(data, "diff state was not registered for " .. tab_name)
  local proposed_buf = data.new_buffer
  local bufhidden = vim.api.nvim_buf_get_option(proposed_buf, "bufhidden")
  local tabs_before = #vim.api.nvim_list_tabpages()

  -- Make the proposed window current and reject with a genuine `:q`, exactly as
  -- the user would. setup_new_buffer leaves the proposed window focused, but be
  -- explicit so the test does not depend on that.
  if data.new_window and vim.api.nvim_win_is_valid(data.new_window) then
    vim.api.nvim_set_current_win(data.new_window)
  end
  pcall(vim.cmd, "quit")

  -- Measure BEFORE any cleanup so we see exactly what `:q` alone did.
  local status_after = (diff._get_active_diffs()[tab_name] or {}).status
  local buf_loaded_after = vim.api.nvim_buf_is_loaded(proposed_buf)
  local tabs_after = #vim.api.nvim_list_tabpages()
  local rejected = captured ~= nil
    and captured.content ~= nil
    and captured.content[1] ~= nil
    and captured.content[1].text == "DIFF_REJECTED"

  return {
    open_in_new_tab = open_in_new_tab,
    proposed_bufhidden = bufhidden,
    rejected = rejected,
    status_after = status_after,
    buf_loaded_after = buf_loaded_after,
    tabs_before = tabs_before,
    tabs_after = tabs_after,
  }
end

---Split the proposed window so the buffer is shown twice, then close the clones one at a time.
---Closing one clone must NOT reject (still visible elsewhere); closing the last must reject ONCE.
---This exercises the load-bearing part of the pattern-less WinClosed handler that the
---single-window scenarios above do not: the "exclude the closing window from the count" arithmetic.
---@return boolean ok, string detail
local function run_multiwindow_scenario()
  reset_editor()
  diff.setup({
    diff_opts = { layout = "vertical", open_in_new_tab = false, keep_terminal_focus = false },
    terminal = { provider = "none" },
  })
  local target = make_target()
  local tab_name = "REPRO238 multiwindow"

  local reject_count = 0
  diff._setup_blocking_diff({
    old_file_path = target,
    new_file_path = target,
    new_file_contents = "line one\nline two\nline three (EDITED BY CLAUDE)\nline four\nline five\n",
    tab_name = tab_name,
  }, function(result)
    if result and result.content and result.content[1] and result.content[1].text == "DIFF_REJECTED" then
      reject_count = reject_count + 1
    end
  end)

  local data = diff._get_active_diffs()[tab_name]
  if not data then
    return false, "diff state was not registered"
  end
  local proposed = data.new_buffer

  -- Split so the proposed buffer is shown in two windows.
  vim.api.nvim_set_current_win(data.new_window)
  vim.cmd("vsplit")
  local wins = vim.fn.win_findbuf(proposed)
  if #wins < 2 then
    return false, ("expected proposed buffer in >=2 windows, got %d"):format(#wins)
  end

  -- Close one clone: must NOT reject (still visible in the other).
  vim.api.nvim_win_close(wins[1], false)
  if reject_count ~= 0 or (diff._get_active_diffs()[tab_name] or {}).status ~= "pending" then
    return false,
      ("closing one split prematurely rejected (count=%d, status=%s)"):format(
        reject_count,
        tostring((diff._get_active_diffs()[tab_name] or {}).status)
      )
  end

  -- Close the last window showing it: must reject exactly once.
  local remaining = vim.fn.win_findbuf(proposed)
  if #remaining > 0 then
    vim.api.nvim_win_close(remaining[1], false)
  end
  if reject_count ~= 1 or (diff._get_active_diffs()[tab_name] or {}).status ~= "rejected" then
    return false,
      ("closing the last split did not reject exactly once (count=%d, status=%s)"):format(
        reject_count,
        tostring((diff._get_active_diffs()[tab_name] or {}).status)
      )
  end

  return true, "split: one close kept pending, last close rejected exactly once"
end

---Reject a NEW-FILE diff (is_new_file=true) with `:q`. With on_new_file_reject="keep_empty"
---(the default), _resolve_diff_as_rejected eagerly runs _cleanup_diff_state, which closes the
---diff window from INSIDE the WinClosed callback -- a re-entrant window close the existing-file
---scenarios never exercise (historically an E1159 "cannot change window layout" risk).
---@return boolean ok, string detail
local function run_newfile_scenario()
  reset_editor()
  diff.setup({
    diff_opts = {
      layout = "vertical",
      open_in_new_tab = false,
      keep_terminal_focus = false,
      on_new_file_reject = "keep_empty",
    },
    terminal = { provider = "none" },
  })

  local newpath = vim.fn.tempname()
  pcall(os.remove, newpath) -- ensure it does NOT exist -> is_new_file = true
  local tab_name = "REPRO238 newfile"

  local rejected = false
  diff._setup_blocking_diff({
    old_file_path = newpath,
    new_file_path = newpath,
    new_file_contents = "brand new line 1\nbrand new line 2\n",
    tab_name = tab_name,
  }, function(result)
    if result and result.content and result.content[1] and result.content[1].text == "DIFF_REJECTED" then
      rejected = true
    end
  end)

  local data = diff._get_active_diffs()[tab_name]
  if not data then
    return false, "new-file diff state was not registered"
  end
  if data.new_window and vim.api.nvim_win_is_valid(data.new_window) then
    vim.api.nvim_set_current_win(data.new_window)
  end
  -- The reject signal fires before the eager cleanup, so `rejected` is set even if the
  -- nested window close is a no-op; a hard error here would surface as quit_ok=false.
  local quit_ok = pcall(vim.cmd, "quit")
  if not rejected then
    return false, ("new-file `:q` did not reject (quit_ok=%s)"):format(tostring(quit_ok))
  end
  return true, "new-file `:q` rejected (eager keep_empty cleanup ran without a hard error)"
end

out("== issue #238 reproduction: reject-with-:q ==")
out(("Neovim: %s"):format(vim.version and tostring(vim.version()) or "?"))

local scenarios = {
  { label = "default config (open_in_new_tab=false)", new_tab = false },
  { label = "reporter config (open_in_new_tab=true)", new_tab = true },
}

local any_bug = false
for _, sc in ipairs(scenarios) do
  local r = run_scenario(sc.new_tab)
  out("")
  out(("[%s]"):format(sc.label))
  out(("  proposed buffer bufhidden = %q"):format(tostring(r.proposed_bufhidden)))
  out(
    ("  after :q -> rejected=%s  status=%s  proposed_buf_still_loaded=%s  tabpages %d->%d"):format(
      tostring(r.rejected),
      tostring(r.status_after),
      tostring(r.buf_loaded_after),
      r.tabs_before,
      r.tabs_after
    )
  )
  if r.rejected then
    out("  => OK: `:q` resolved the diff as DIFF_REJECTED")
  else
    out("  => BUG: `:q` did NOT reject the diff (Claude never receives DIFF_REJECTED)")
    any_bug = true
  end
end

out("")
out("[multi-window: split the proposed buffer, close clones one at a time]")
local mw_ok, mw_detail = run_multiwindow_scenario()
if mw_ok then
  out("  => OK: " .. mw_detail)
else
  out("  => BUG: " .. mw_detail)
  any_bug = true
end

out("")
out("[new file: reject a not-yet-existing file's diff with :q (re-entrant keep_empty cleanup)]")
local nf_ok, nf_detail = run_newfile_scenario()
if nf_ok then
  out("  => OK: " .. nf_detail)
else
  out("  => BUG: " .. nf_detail)
  any_bug = true
end

reset_editor()
pcall(os.remove, target_path)

out("")
out("== verdict ==")
if any_bug then
  out("BUG REPRODUCED: `:q` fails to reject the Claude diff (issue #238).")
else
  out("FIXED: `:q` rejects the Claude diff in every scenario.")
end

io.stdout:flush()
vim.cmd("cquit " .. (any_bug and 1 or 0))
