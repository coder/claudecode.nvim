-- Reproduction / verification for issue #208:
--   "[BUG] Leftover [No Name] tab after diff resolve with open_in_new_tab and
--    terminal.provider = none"
--   https://github.com/coder/claudecode.nvim/issues/208
--
-- Scenario from the report:
--   opts = {
--     terminal  = { provider = "none" },          -- Claude runs in an EXTERNAL terminal
--     diff_opts = { open_in_new_tab = true },     -- each diff opens in its own tab
--   }
-- Resolving a diff (accept AND reject) leaves behind an empty `[No Name]` tab /
-- buffer that is never cleaned up. A commenter confirms: "We start collecting
-- empty buffers on every new diff tab."
--
-- Why provider = "none" matters
-- ------------------------------
-- diff.lua opens the new tab via display_terminal_in_new_tab(). With a terminal
-- (snacks/native) it runs the full path that marks the initial unnamed buffer
-- `bufhidden=wipe` (diff.lua ~320-332). With provider = "none" there is no
-- terminal buffer, so the helper EARLY-RETURNS at the `:tabnew` site
-- (diff.lua ~303-306) WITHOUT marking that buffer ephemeral, and returns
-- terminal_win_in_new_tab = nil. choose_original_window() derives
-- `in_new_tab = terminal_win_in_new_tab ~= nil` (diff.lua ~565), so it thinks it
-- is NOT in a new tab and REUSES the bare `[No Name]` buffer as the diff's
-- original side -- a buffer that is never marked ephemeral and (for new files)
-- never deleted on cleanup because original_buffer_created_by_plugin = false.
--
-- This script drives the REAL diff.lua against the open_in_new_tab path with no
-- WebSocket / Claude CLI. It exercises the exact functions the MCP layer calls:
--   * open:    M._setup_blocking_diff (what the openDiff tool runs)
--   * accept:  M._resolve_diff_as_saved  + M.close_diff_by_tab_name (close_tab)
--   * reject:  M._resolve_diff_as_rejected + M.close_diff_by_tab_name (close_tab)
-- (Accept/reject themselves intentionally do NOT touch tabs/windows; cleanup is
-- driven exclusively by Claude's close_tab call -> _cleanup_diff_state. See the
-- NOTE comments in _resolve_diff_as_saved / deny_current_diff.)
--
-- Run from the repo root:
--   nvim --headless -u NONE -l scripts/repro_issue_208.lua
--
-- Exit code: 1 if ANY scenario leaks a tab or a `[No Name]` buffer (#208
-- reproduced), 0 if all clean. The detailed verdict is printed either way.

local script_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ":h:h")
vim.opt.rtp:prepend(repo_root)

local function out(msg)
  io.stdout:write(msg .. "\n")
end

local diff = require("claudecode.diff")

-- Force the provider = "none" code path deterministically: pre-load the terminal
-- module and make get_active_terminal_bufnr() report "no terminal", so
-- display_terminal_in_new_tab() takes the early-return `:tabnew` branch
-- regardless of the host environment. This is exactly what provider = "none"
-- produces at runtime (no terminal buffer ever exists).
local terminal = require("claudecode.terminal")
terminal.get_active_terminal_bufnr = function()
  return nil
end

diff.setup({
  diff_opts = {
    layout = "vertical",
    open_in_new_tab = true, -- the path under test
    keep_terminal_focus = false,
    on_new_file_reject = "keep_empty",
  },
  terminal = { provider = "none" },
})

local function count_tabs()
  return vim.fn.tabpagenr("$")
end

-- Set of valid, listed buffers whose name is empty -> these are the `[No Name]`
-- buffers the issue is about. Returned as a handle->true map so we can diff two
-- snapshots and report only NEWLY-leaked buffers.
local function noname_bufs()
  local set = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      local name = vim.api.nvim_buf_get_name(b)
      local listed = vim.api.nvim_buf_get_option(b, "buflisted")
      if name == "" and listed then
        set[b] = true
      end
    end
  end
  return set
end

local function set_diff(after, before)
  local new = {}
  for b in pairs(after) do
    if not before[b] then
      new[#new + 1] = b
    end
  end
  return new
end

-- Collapse to a single clean tab/window so each scenario starts fresh, then wipe
-- every stray `[No Name]` buffer so the per-scenario baseline is genuinely empty.
local function reset_layout()
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("silent! enew!")
  diff._cleanup_all_active_diffs("repro reset")
  -- Wipe leaked no-name buffers from a previous scenario (except the current one).
  local cur = vim.api.nvim_get_current_buf()
  for b in pairs(noname_bufs()) do
    if b ~= cur then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

local function make_old_file(tag)
  local p = vim.fn.tempname() .. "_" .. tag .. ".md"
  local fh = io.open(p, "w")
  fh:write("# original\n\nline one\nline two\n")
  fh:close()
  return p
end

-- A path that does NOT exist on disk -> is_new_file = true inside diff.lua.
local function make_new_file_path(tag)
  return vim.fn.tempname() .. "_" .. tag .. "_new.md"
end

---@param name string
---@param is_new_file boolean
---@param mode "accept"|"reject"
local function run_scenario(name, is_new_file, mode)
  reset_layout()

  local tabs_before = count_tabs()
  local noname_before = noname_bufs()
  local orig_tab = vim.api.nvim_get_current_tabpage()

  local tab_name = ("✻ [Claude Code] repro208_%s ⧉"):format(name)
  local old_file
  if is_new_file then
    old_file = make_new_file_path(name)
  else
    old_file = make_old_file(name)
  end

  local setup_ok, setup_err = pcall(function()
    diff._setup_blocking_diff({
      old_file_path = old_file,
      new_file_path = old_file,
      new_file_contents = "# proposed by Claude\n\nNEW line one\nline two\n",
      tab_name = tab_name,
    }, function() end)
  end)

  local tabs_during = count_tabs()

  -- Resolve exactly as the MCP layer does.
  if setup_ok then
    local active = diff._get_active_diffs()[tab_name]
    if mode == "accept" then
      -- :w in the proposed buffer -> BufWriteCmd -> _resolve_diff_as_saved
      if active and active.new_buffer then
        diff._resolve_diff_as_saved(tab_name, active.new_buffer)
      end
    else
      -- reject keymap / :q -> _resolve_diff_as_rejected
      diff._resolve_diff_as_rejected(tab_name)
    end
    -- Claude then sends close_tab -> close_diff_by_tab_name -> _cleanup_diff_state
    diff.close_diff_by_tab_name(tab_name)
  end

  -- close_diff_by_tab_name's saved branch defers a buffer reload by 100ms; give
  -- any deferred work a chance to run before we measure.
  vim.wait(250, function()
    return false
  end)

  local tabs_after = count_tabs()
  local noname_after = noname_bufs()
  local cur_tab = vim.api.nvim_get_current_tabpage()

  local leaked_tab = tabs_after > tabs_before
  local leaked_bufs = set_diff(noname_after, noname_before)
  local refocused = cur_tab == orig_tab

  out(("\n[%s | %s | %s]"):format(name, is_new_file and "NEW file" or "existing file", mode))
  out(("  setup            : %s"):format(setup_ok and "OK" or ("ERROR -- " .. tostring(setup_err))))
  out(
    ("  tabs             : before=%d  during=%d  after=%d  %s"):format(
      tabs_before,
      tabs_during,
      tabs_after,
      leaked_tab and "<< LEFTOVER TAB" or "(tab cleaned)"
    )
  )
  out(
    ("  [No Name] bufs   : before=%d  after=%d  leaked=%d  %s"):format(
      vim.tbl_count(noname_before),
      vim.tbl_count(noname_after),
      #leaked_bufs,
      (#leaked_bufs > 0) and ("<< LEAKED " .. vim.inspect(leaked_bufs):gsub("%s+", " ")) or "(no buffer leak)"
    )
  )
  out(("  focus            : %s"):format(refocused and "back on original tab" or "left elsewhere"))

  os.remove(old_file)

  return {
    name = name,
    is_new_file = is_new_file,
    mode = mode,
    leaked_tab = leaked_tab,
    leaked_bufs = #leaked_bufs,
  }
end

out("== issue #208 reproduction (open_in_new_tab + provider=none leaves [No Name] tab/buffer) ==")
out(("Neovim: %s"):format(tostring(vim.version())))

local results = {}
results[#results + 1] = run_scenario("existing_accept", false, "accept")
results[#results + 1] = run_scenario("existing_reject", false, "reject")
results[#results + 1] = run_scenario("new_accept", true, "accept")
results[#results + 1] = run_scenario("new_reject", true, "reject")

-- Accumulation check: open+resolve several diffs in a row WITHOUT wiping no-name
-- buffers between them, to confirm the reported "collecting empty buffers on
-- every new diff tab". Uses existing-file accept (the most common real action).
out("\n[accumulation: 3x existing-file accept, no buffer wipe between]")
vim.cmd("silent! tabonly!")
vim.cmd("silent! only!")
vim.cmd("silent! enew!")
diff._cleanup_all_active_diffs("accum reset")
for b in pairs(noname_bufs()) do
  if b ~= vim.api.nvim_get_current_buf() then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end
local accum_before = vim.tbl_count(noname_bufs())
for i = 1, 3 do
  local tab_name = ("✻ [Claude Code] repro208_accum_%d ⧉"):format(i)
  local old_file = make_old_file("accum_" .. i)
  pcall(function()
    diff._setup_blocking_diff({
      old_file_path = old_file,
      new_file_path = old_file,
      new_file_contents = "# proposed " .. i .. "\n\nNEW line one\nline two\n",
      tab_name = tab_name,
    }, function() end)
    local active = diff._get_active_diffs()[tab_name]
    if active and active.new_buffer then
      diff._resolve_diff_as_saved(tab_name, active.new_buffer)
    end
    diff.close_diff_by_tab_name(tab_name)
  end)
  vim.wait(200, function()
    return false
  end)
  os.remove(old_file)
end
local accum_after = vim.tbl_count(noname_bufs())
local accum_tabs = count_tabs()
out(
  ("  [No Name] bufs   : before=%d  after 3 diffs=%d  (delta=%d)"):format(
    accum_before,
    accum_after,
    accum_after - accum_before
  )
)
out(("  tabs             : after 3 diffs=%d %s"):format(accum_tabs, accum_tabs > 1 and "<< LEFTOVER TABS" or "(clean)"))

out("\n== verdict ==")
local any_leak = false
for _, r in ipairs(results) do
  local leak = r.leaked_tab or r.leaked_bufs > 0
  any_leak = any_leak or leak
  out(
    ("  %-16s %-13s %-7s : %s"):format(
      r.name,
      r.is_new_file and "NEW file" or "existing",
      r.mode,
      leak and (("LEAK (tab=%s, bufs=%d)"):format(tostring(r.leaked_tab), r.leaked_bufs)) or "clean"
    )
  )
end
local accum_leak = (accum_after - accum_before) > 0 or accum_tabs > 1
any_leak = any_leak or accum_leak
out(
  ("  %-16s %-13s %-7s : %s"):format(
    "accumulation",
    "existing",
    "3x accept",
    accum_leak and (("LEAK (%d buffers, %d tabs)"):format(accum_after - accum_before, accum_tabs)) or "clean"
  )
)

if any_leak then
  out("\n=> #208 confirmed: open_in_new_tab + provider=none leaks a [No Name] tab and/or buffer on diff resolve.")
else
  out("\n=> FIXED: no leftover tab or [No Name] buffer after diff resolve.")
end

io.stdout:flush()
vim.cmd("cquit " .. (any_leak and 1 or 0))
