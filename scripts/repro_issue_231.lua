-- Reproduction / verification for issue #231:
--   "When the Claude Code terminal is the only window (no other splits), an
--    error is generated when Claude tries to suggest changes."
--   https://github.com/coder/claudecode.nvim/issues/231
--
-- The bug: with a single `buftype=terminal` window, diff.lua's
-- find_main_editor_window() returns nil (it correctly excludes terminals). The
-- fix makes M._setup_blocking_diff create a split to host the diff instead of
-- erroring with "No suitable editor window found".
--
-- This script drives the REAL diff.lua against a terminal-only layout, with no
-- WebSocket/Claude CLI needed. It exercises the exact code path the openDiff MCP
-- tool uses (M._setup_blocking_diff), so it both reproduces the original bug (on
-- unfixed code) and verifies the fix.
--
-- Run from the repo root:
--   nvim --headless -u NONE -l scripts/repro_issue_231.lua
--
-- Exit code: 0 if the diff opens (fixed), 1 if the #231 error is reproduced.
-- The detailed verdict is printed to stdout either way.

local script_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ":h:h")
vim.opt.rtp:prepend(repo_root)

local function out(msg)
  io.stdout:write(msg .. "\n")
end

local diff = require("claudecode.diff")

---Make a `buftype=terminal` window the ONLY window (the issue #231 layout).
local function make_terminal_only_window()
  vim.cmd("silent! only")
  vim.cmd("enew!")
  -- jobstart({term=true}) (Neovim 0.11+) / fallback to termopen on older versions.
  if vim.fn.has("nvim-0.11") == 1 then
    vim.fn.jobstart({ "cat" }, { term = true })
  else
    vim.fn.termopen({ "cat" })
  end
  vim.cmd("silent! only")
  return #vim.api.nvim_list_wins(), vim.api.nvim_buf_get_option(0, "buftype")
end

---Run M._setup_blocking_diff for a brand-new file and capture the outcome.
---@return boolean ok, string detail
local function try_open_diff()
  local new_file = repo_root .. "/__issue_231_repro__.md"
  os.remove(new_file) -- ensure is_new_file = true (matches: Claude proposing a new file)
  local ok, err = pcall(function()
    diff._setup_blocking_diff({
      old_file_path = new_file,
      new_file_path = new_file,
      new_file_contents = "# Proposed by Claude\n\nhello\n",
      tab_name = "✻ [Claude Code] __issue_231_repro__.md (445ca6) ⧉",
    }, function() end)
  end)
  -- Best-effort cleanup of any windows/diff state the setup created.
  pcall(function()
    diff._cleanup_all_active_diffs("repro cleanup")
  end)
  if ok then
    return true, "setup SUCCEEDED (a window was found or created)"
  end
  local msg = type(err) == "table" and (tostring(err.message) .. " - " .. tostring(err.data)) or tostring(err)
  return false, msg
end

out("== issue #231 reproduction ==")
out(("Neovim: %s"):format(vim.version and tostring(vim.version()) or vim.fn.execute("version"):match("NVIM[^\n]*")))

-- Scenario A: default diff_opts (open_in_new_tab = false) -- the path that regressed in #231.
-- This exercises the actual fix (find_main_editor_window -> nil -> create a split fallback).
diff.setup({ diff_opts = { layout = "vertical", open_in_new_tab = false } })
local wins, bt = make_terminal_only_window()
out(("\n[A] default config  | precondition: windows=%d, only buftype=%q"):format(wins, bt))
local a_ok, a_detail = try_open_diff()
out(("[A] result: %s -> %s"):format(a_ok and "OK" or "ERROR", a_detail))

-- Scenario B: open_in_new_tab = true -- a pre-existing WORKAROUND. NOTE: this does NOT exercise
-- the #231 fix path; the new-tab path creates its own window and never calls
-- find_main_editor_window, so it succeeds even on unfixed code. Included only to confirm the
-- documented workaround still works; scenario A is the real regression signal.
diff.setup({ diff_opts = { layout = "vertical", open_in_new_tab = true } })
wins, bt = make_terminal_only_window()
out(("\n[B] open_in_new_tab=true | precondition: windows=%d, only buftype=%q"):format(wins, bt))
local b_ok, b_detail = try_open_diff()
out(("[B] result: %s -> %s"):format(b_ok and "OK" or "ERROR", b_detail))

out("\n== verdict ==")
local bug_reproduced = (not a_ok) and a_detail:match("No suitable editor window found") ~= nil
if bug_reproduced then
  out("BUG REPRODUCED: default config errors with 'No suitable editor window found' (issue #231).")
else
  out("FIXED: default config opens the diff in a terminal-only layout (scenario A).")
end
if b_ok then
  out("WORKAROUND OK: diff_opts.open_in_new_tab=true opens the diff in a new tab (does not exercise the fix).")
else
  out("NOTE: open_in_new_tab=true did NOT open the diff in this environment: " .. b_detail)
end

io.stdout:flush()
vim.cmd("cquit " .. (bug_reproduced and 1 or 0))
