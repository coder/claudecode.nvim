-- Reproduction / verification for issue #262:
--   "diff: open_in_new_tab can strand a tab if setup errors before the diff
--    state is registered"
--   https://github.com/coder/claudecode.nvim/issues/262
--
-- The bug: with diff_opts.open_in_new_tab = true, M._setup_blocking_diff calls
-- display_terminal_in_new_tab() EARLY (it runs `:tabnew`). If setup then throws
-- before M._register_diff_state runs, the post-pcall error handler cannot close
-- that tab:
--   * the state-based cleanup is gated on a registered diff (none exists yet);
--   * the pre-registration `else` branch (added in #260) only closes
--     `fallback_window` and deletes `new_buffer`;
--   * `new_tab_handle` is declared INSIDE the pcall closure, so the error
--     handler can't even reach it.
-- Result: one stranded extra tab per failed setup, and the original tab is not
-- refocused.
--
-- This script drives the REAL diff.lua against the open_in_new_tab path, with no
-- WebSocket/Claude CLI needed. It exercises the exact code path the openDiff MCP
-- tool uses (M._setup_blocking_diff), so it both reproduces the bug (on unfixed
-- code) and will verify the fix.
--
-- Run from the repo root:
--   nvim --headless -u NONE -l scripts/repro_issue_262.lua
--
-- Exit code: 1 if ANY scenario strands a tab (#262 reproduced), 0 if all clean.
-- The detailed verdict is printed to stdout either way.

local script_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ":h:h")
vim.opt.rtp:prepend(repo_root)

local function out(msg)
  io.stdout:write(msg .. "\n")
end

local diff = require("claudecode.diff")

local function count_tabs()
  return vim.fn.tabpagenr("$")
end

-- Collapse to a single clean tab/window so each scenario starts from tabs == 1.
local function reset_layout()
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("silent! enew!")
  diff._cleanup_all_active_diffs("repro reset")
end

-- Write a throwaway "existing" old file (so is_new_file = false and the
-- existing-file path that runs `:edit old_file_path` is exercised).
local function make_old_file(tag)
  local p = vim.fn.tempname() .. "_" .. tag .. ".md"
  local fh = io.open(p, "w")
  fh:write("# original\n\nline one\nline two\n")
  fh:close()
  return p
end

diff.setup({
  diff_opts = {
    layout = "vertical",
    open_in_new_tab = true, -- the path under test
    keep_terminal_focus = false,
    on_new_file_reject = "keep_empty",
  },
  terminal = {},
})

---@class ScenarioResult
---@field name string
---@field stranded boolean
---@field refocused boolean
---@field before number
---@field after number

---@param name string
---@param run fun() -- arranges the forced failure and calls _setup_blocking_diff
---@return ScenarioResult
local function run_scenario(name, run)
  reset_layout()
  local before = count_tabs()
  local orig_tab = vim.api.nvim_get_current_tabpage()

  local ok, err = pcall(run)

  local after = count_tabs()
  local cur_tab = vim.api.nvim_get_current_tabpage()
  local stranded = after > before
  local refocused = cur_tab == orig_tab

  out(("\n[%s]"):format(name))
  out(("  setup result : %s"):format(ok and "OK (no error -- unexpected)" or "ERROR (expected)"))
  if not ok then
    local msg = type(err) == "table" and (tostring(err.message) .. " / " .. tostring(err.data)) or tostring(err)
    -- Keep enough of the message that the underlying cause (e.g. the BufReadPre failure in
    -- scenario B) is visible past Neovim's nvim_exec2 wrapper prefix.
    out(("  error        : %s"):format((msg:gsub("%s+", " ")):sub(1, 240)))
  end
  out(("  tabs         : before=%d  after=%d  %s"):format(before, after, stranded and "<< STRANDED" or "(clean)"))
  out(("  focus        : %s"):format(refocused and "back on original tab" or "LEFT ON STRANDED TAB"))

  return { name = name, stranded = stranded, refocused = refocused, before = before, after = after }
end

out("== issue #262 reproduction (open_in_new_tab strands a tab on early setup error) ==")
out(("Neovim: %s"):format(tostring(vim.version())))

-- Scenario A: deterministic. Stub _create_diff_view_from_window to throw. In
-- _setup_blocking_diff this is called (line ~1252) AFTER display_terminal_in_new_tab()
-- has already run `:tabnew` (line ~1173) and AFTER new_buffer is created, but BEFORE
-- _register_diff_state. This isolates the exact "error between tab creation and state
-- registration" window the issue describes, independent of any specific trigger.
local results = {}
results[#results + 1] = run_scenario("A: deterministic (stub _create_diff_view_from_window)", function()
  local old_file = make_old_file("A")
  local original = diff._create_diff_view_from_window
  diff._create_diff_view_from_window = function()
    error({ code = -32000, message = "simulated failure", data = "after tabnew, before register" })
  end
  local fin = function()
    diff._create_diff_view_from_window = original
    os.remove(old_file)
  end
  local ok, err = pcall(function()
    diff._setup_blocking_diff({
      old_file_path = old_file,
      new_file_path = old_file,
      new_file_contents = "# proposed by Claude\n\nNEW line one\nline two\n",
      tab_name = "✻ [Claude Code] repro262_A.md ⧉",
    }, function() end)
  end)
  fin()
  if not ok then
    error(err)
  end
end)

-- Scenario B: realistic trigger from the issue. A user BufReadPre autocmd that
-- throws when the original file is :edit-ed (load_original_buffer ->
-- `vim.cmd("edit " .. fnameescape(old_file_path))`). This is a real-world path:
-- a plugin/autocmd erroring on read, a swap-file conflict, etc. all surface here.
results[#results + 1] = run_scenario("B: realistic (throwing BufReadPre autocmd on :edit)", function()
  local old_file = make_old_file("B")
  local grp = vim.api.nvim_create_augroup("repro262_bufreadpre", { clear = true })
  vim.api.nvim_create_autocmd("BufReadPre", {
    group = grp,
    pattern = old_file,
    callback = function()
      error("simulated BufReadPre failure (#262 realistic trigger)")
    end,
  })
  local fin = function()
    pcall(vim.api.nvim_del_augroup_by_id, grp)
    os.remove(old_file)
  end
  local ok, err = pcall(function()
    diff._setup_blocking_diff({
      old_file_path = old_file,
      new_file_path = old_file,
      new_file_contents = "# proposed by Claude\n\nNEW line one\nline two\n",
      tab_name = "✻ [Claude Code] repro262_B.md ⧉",
    }, function() end)
  end)
  fin()
  if not ok then
    error(err)
  end
end)

-- Control: same open_in_new_tab path, but setup SUCCEEDS (no forced error) and is
-- then torn down via the normal cleanup (_cleanup_diff_state). This proves the
-- harness is sound: a `:tabnew`-created tab that is properly registered DOES get
-- closed, so the 1 -> 2 growth in A/B above is a genuine leak, not just "tabnew
-- always adds a tab".
local control = (function()
  reset_layout()
  local before = count_tabs()
  local tab_name = "✻ [Claude Code] repro262_control.md ⧉"
  local old_file = make_old_file("control")
  local mid, after
  local ok, err = pcall(function()
    diff._setup_blocking_diff({
      old_file_path = old_file,
      new_file_path = old_file,
      new_file_contents = "# proposed by Claude\n\nNEW line one\nline two\n",
      tab_name = tab_name,
    }, function() end)
    mid = count_tabs() -- tab created and registered
    diff._cleanup_diff_state(tab_name, "repro control cleanup")
  end)
  after = count_tabs()
  os.remove(old_file)
  out("\n[C: control (setup succeeds, then normal cleanup)]")
  out(("  setup result : %s"):format(ok and "OK (expected)" or ("ERROR -- " .. tostring(err))))
  out(
    ("  tabs         : before=%d  during=%s  after_cleanup=%d  %s"):format(
      before,
      tostring(mid),
      after,
      (after == before) and "(cleaned up)" or "<< LEAK"
    )
  )
  return { ok = ok, before = before, mid = mid, after = after, clean = (after == before) }
end)()

out("\n== verdict ==")
local any_stranded = false
for _, r in ipairs(results) do
  if r.stranded then
    any_stranded = true
    out(
      ("BUG REPRODUCED [%s]: %d -> %d tabs (one stranded)%s"):format(
        r.name,
        r.before,
        r.after,
        r.refocused and "" or "; original tab not refocused"
      )
    )
  else
    out(("OK [%s]: tab count unchanged (%d)"):format(r.name, r.after))
  end
end

out(
  ("CONTROL [C]: %s"):format(
    control.clean and "harness sound (registered tab is cleaned up; leak in A/B is real)"
      or "WARNING -- control did not clean up; harness suspect"
  )
)

if any_stranded then
  out("\n=> #262 confirmed: open_in_new_tab strands a tab when setup errors before the diff state is registered.")
else
  out("\n=> FIXED: no tab was stranded on early setup failure.")
end

io.stdout:flush()
vim.cmd("cquit " .. (any_stranded and 1 or 0))
