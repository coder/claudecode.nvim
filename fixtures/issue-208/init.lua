-- Fixture for issue #208:
--   "[BUG] Leftover [No Name] tab after diff resolve with open_in_new_tab and
--    terminal.provider = none"
--   https://github.com/coder/claudecode.nvim/issues/208
--
-- Repro config from the report:
--   terminal  = { provider = "none" }        -- Claude runs in an EXTERNAL terminal
--   diff_opts = { open_in_new_tab = true }   -- each diff opens in its own tab
--
-- With provider = "none" there is no in-Neovim terminal buffer, so the new-tab
-- helper (display_terminal_in_new_tab) early-returns right after `:tabnew`
-- WITHOUT marking the bare `[No Name]` buffer ephemeral, and reports "no terminal
-- window". choose_original_window() then treats the diff as NOT in a new tab and
-- REUSES that empty buffer as the diff's original side. On a NEW-file diff that
-- reused buffer is never deleted on cleanup (original_buffer_created_by_plugin is
-- false), so it leaks -- "collecting empty buffers on every new diff tab".
--
-- This fixture drives the diff through the exact functions the openDiff /
-- close_tab MCP path uses, so NO external Claude is required to see the leak.
--
-- Usage (from repo root):
--   source fixtures/nvim-aliases.sh && vv issue-208
-- Watch the tabline counter "noname=N". Then:
--   <leader>x          open+ACCEPT a NEW-file diff      -> noname count GROWS  (BUG)
--   :Repro208NewReject open+REJECT a NEW-file diff      -> noname count GROWS  (BUG)
--   :Repro208Existing  open+accept an EXISTING-file diff-> noname count steady (control)
--   :Repro208Buffers   print the leaked [No Name] buffers (:ls-style)
--   :Repro208Reset     collapse to one tab + wipe stray no-name buffers

local config_dir = vim.fn.stdpath("config")
local repo_root = vim.fn.fnamemodify(config_dir, ":h:h")
vim.opt.rtp:prepend(repo_root)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Count valid, listed buffers with an empty name -> the leaked `[No Name]` buffers.
local function noname_count()
  local n = 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == "" and vim.bo[b].buflisted then
      n = n + 1
    end
  end
  return n
end

-- Always show the tabline with a live [No Name] buffer counter, so the leak is
-- visible without typing any command.
vim.o.showtabline = 2
vim.o.laststatus = 2
function _G.Repro208Tabline()
  local s = {}
  for i = 1, vim.fn.tabpagenr("$") do
    local active = (i == vim.fn.tabpagenr())
    local winnr = vim.fn.tabpagewinnr(i)
    local buflist = vim.fn.tabpagebuflist(i)
    local bufname = vim.fn.bufname(buflist[winnr])
    local label = (bufname == "" and "[No Name]" or vim.fn.fnamemodify(bufname, ":t"))
    s[#s + 1] = (active and "%#TabLineSel#" or "%#TabLine#")
    s[#s + 1] = (" TAB %d%s: %s "):format(i, active and " (active)" or "", label)
  end
  s[#s + 1] = "%#TabLineFill#"
  s[#s + 1] = "%=%#WarningMsg# noname=" .. noname_count() .. "  tabs=" .. vim.fn.tabpagenr("$") .. " "
  return table.concat(s)
end
vim.o.tabline = "%!v:lua.Repro208Tabline()"

local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

claudecode.setup({
  auto_start = false,
  log_level = "info",
  terminal = {
    provider = "none", -- the path under test (#208): Claude runs externally
  },
  diff_opts = {
    layout = "vertical",
    open_in_new_tab = true, -- the path under test (#208)
    keep_terminal_focus = false,
    on_new_file_reject = "keep_empty",
  },
})

local diff = require("claudecode.diff")

-- Drive one diff through the real MCP code path with no external Claude:
--   open  -> M._setup_blocking_diff  (what the openDiff tool runs)
--   accept-> M._resolve_diff_as_saved (what BufWriteCmd / :w runs)
--   reject-> M._resolve_diff_as_rejected (what the reject keymap runs)
--   close -> M.close_diff_by_tab_name (what Claude's close_tab notification runs)
---@param is_new_file boolean
---@param mode "accept"|"reject"
local function run_one(is_new_file, mode)
  local before = noname_count()

  local tag = (is_new_file and "new" or "existing") .. "_" .. mode
  local tab_name = ("✻ [Claude Code] issue208_%s ⧉"):format(tag)

  local old_file
  if is_new_file then
    old_file = vim.fn.tempname() .. "_issue208_" .. tag .. "_NEW.md" -- not created -> is_new_file
  else
    old_file = vim.fn.tempname() .. "_issue208_" .. tag .. ".md"
    local fh = io.open(old_file, "w")
    fh:write("# original\n\nline one\nline two\n")
    fh:close()
  end

  pcall(function()
    diff._setup_blocking_diff({
      old_file_path = old_file,
      new_file_path = old_file,
      new_file_contents = "# proposed by Claude\n\nNEW line one\nline two\n",
      tab_name = tab_name,
    }, function() end)
    local active = diff._get_active_diffs()[tab_name]
    if mode == "accept" then
      if active and active.new_buffer then
        diff._resolve_diff_as_saved(tab_name, active.new_buffer)
      end
    else
      diff._resolve_diff_as_rejected(tab_name)
    end
    diff.close_diff_by_tab_name(tab_name)
  end)

  -- close_diff_by_tab_name's saved branch defers a reload by 100ms.
  vim.wait(250, function()
    return false
  end)
  if not is_new_file then
    os.remove(old_file)
  end

  local after = noname_count()
  local delta = after - before
  vim.api.nvim_echo({
    {
      ("issue208 [%s]: [No Name] bufs %d -> %d (delta=%+d)%s"):format(
        tag,
        before,
        after,
        delta,
        delta > 0 and "  <<< LEAKED" or "  (clean)"
      ),
      delta > 0 and "ErrorMsg" or "MoreMsg",
    },
  }, false, {})
end

vim.api.nvim_create_user_command("Repro208New", function()
  run_one(true, "accept")
end, { desc = "#208: open+ACCEPT a NEW-file diff (leaks a [No Name] buffer)" })

vim.api.nvim_create_user_command("Repro208NewReject", function()
  run_one(true, "reject")
end, { desc = "#208: open+REJECT a NEW-file diff (leaks a [No Name] buffer)" })

vim.api.nvim_create_user_command("Repro208Existing", function()
  run_one(false, "accept")
end, { desc = "#208: open+accept an EXISTING-file diff (control, clean)" })

vim.api.nvim_create_user_command("Repro208Buffers", function()
  local lines = { "Leaked [No Name] listed buffers:" }
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == "" and vim.bo[b].buflisted then
      local loaded = vim.api.nvim_buf_is_loaded(b)
      lines[#lines + 1] = ("  buf %d  loaded=%s  lines=%d"):format(
        b,
        tostring(loaded),
        loaded and vim.api.nvim_buf_line_count(b) or -1
      )
    end
  end
  lines[#lines + 1] = ("total noname=%d  tabs=%d"):format(noname_count(), vim.fn.tabpagenr("$"))
  vim.api.nvim_echo({ { table.concat(lines, "\n"), "MoreMsg" } }, true, {})
end, { desc = "#208: list leaked [No Name] buffers" })

vim.api.nvim_create_user_command("Repro208Reset", function()
  diff._cleanup_all_active_diffs("repro reset")
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("silent! enew!")
  local cur = vim.api.nvim_get_current_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= cur and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == "" and vim.bo[b].buflisted then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  vim.api.nvim_echo(
    { { ("Repro208Reset: noname=%d  tabs=%d"):format(noname_count(), vim.fn.tabpagenr("$")), "MoreMsg" } },
    false,
    {}
  )
end, { desc = "#208: reset layout + wipe stray no-name buffers" })

vim.keymap.set("n", "<leader>x", function()
  run_one(true, "accept")
end, { desc = "#208 repro: open+accept a NEW-file diff" })

-- A normal editor buffer in the first tab so the layout looks like real usage.
local banner = {
  "claudecode.nvim -- issue #208 reproduction fixture",
  "",
  "terminal.provider   = none      (Claude runs in an external terminal)",
  "diff_opts.open_in_new_tab = true (each diff opens in its own tab)",
  "",
  "Watch the tabline (top-right): noname=N  tabs=M",
  "",
  "  <leader>x           open+ACCEPT a NEW-file diff   -> noname GROWS (BUG #208)",
  "  :Repro208NewReject  open+REJECT a NEW-file diff   -> noname GROWS (BUG #208)",
  "  :Repro208Existing   open+accept EXISTING file     -> noname steady (control)",
  "  :Repro208Buffers    print the leaked [No Name] buffers",
  "  :Repro208Reset      collapse to one tab + wipe stray buffers",
  "",
  "Each NEW-file diff leaves one extra unnamed buffer behind (both accept and",
  "reject). Existing-file diffs are clean because the reused empty buffer is",
  "`:edit`-ed over and auto-wiped.",
}
vim.api.nvim_buf_set_lines(0, 0, -1, false, banner)
vim.bo.modifiable = false
vim.bo.modified = false
