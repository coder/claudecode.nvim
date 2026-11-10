-- Fixture for issue #262:
--   "diff: open_in_new_tab can strand a tab if setup errors before the diff
--    state is registered"
--   https://github.com/coder/claudecode.nvim/issues/262
--
-- This fixture configures diff_opts.open_in_new_tab = true and provides a single
-- trigger (:ReproStrandTab / <leader>x) that exercises the realistic failure: a
-- user BufReadPre autocmd throws while the original file is :edit-ed during diff
-- setup. Because the error happens AFTER display_terminal_in_new_tab() ran
-- `:tabnew` but BEFORE the diff state is registered, the post-pcall error handler
-- cannot close the new tab -> it is stranded, and focus is left on it.
--
-- Usage (from repo root):
--   source fixtures/nvim-aliases.sh && vv issue-262
-- then press <leader>x (or run :ReproStrandTab). Watch the tabline jump from one
-- tab to two; the extra empty tab is the stranded one (#262).

local config_dir = vim.fn.stdpath("config")
local repo_root = vim.fn.fnamemodify(config_dir, ":h:h")
vim.opt.rtp:prepend(repo_root)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- Always show the tabline so the stranded tab is visible, with an explicit,
-- unambiguous label per tab (number + active marker + buffer name).
vim.o.showtabline = 2
vim.o.laststatus = 2
function _G.Repro262Tabline()
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
  return table.concat(s)
end
vim.o.tabline = "%!v:lua.Repro262Tabline()"

local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

claudecode.setup({
  auto_start = false,
  log_level = "info",
  terminal = {
    provider = "native",
    auto_close = false,
  },
  diff_opts = {
    layout = "vertical",
    open_in_new_tab = true, -- the path under test (#262)
    keep_terminal_focus = false,
    on_new_file_reject = "keep_empty",
  },
})

-- A normal editor buffer in the first tab so the layout looks like real usage.
local banner = {
  "claudecode.nvim -- issue #262 reproduction fixture",
  "",
  "diff_opts.open_in_new_tab = true",
  "",
  "Press <leader>x (space then x) or run :ReproStrandTab",
  "",
  "Expected on UNFIXED code: the tabline jumps from 1 tab to 2,",
  "and focus is left on the new, EMPTY tab -- that extra tab is",
  "stranded because diff setup errored before the diff state was",
  "registered, so neither cleanup path can close it.",
}
vim.api.nvim_buf_set_lines(0, 0, -1, false, banner)
vim.bo.modifiable = false
vim.bo.modified = false

---Trigger the realistic #262 failure: a throwing BufReadPre autocmd fires while
---diff setup runs `:edit <old_file>`, after the new tab was already created.
local function repro_strand_tab()
  -- Assert the diff module config (defensive; claudecode.setup already did this).
  local diff = require("claudecode.diff")
  diff.setup({
    diff_opts = { layout = "vertical", open_in_new_tab = true, on_new_file_reject = "keep_empty" },
    terminal = {},
  })

  local before = vim.fn.tabpagenr("$")

  -- A fresh on-disk file that is NOT already loaded, so `:edit` reads it and
  -- fires BufReadPre (where our autocmd throws).
  local old_file = vim.fn.tempname() .. "_issue262.md"
  local fh = io.open(old_file, "w")
  fh:write("# original\n\nline one\nline two\n")
  fh:close()

  local grp = vim.api.nvim_create_augroup("repro262", { clear = true })
  vim.api.nvim_create_autocmd("BufReadPre", {
    group = grp,
    pattern = old_file,
    callback = function()
      error("simulated BufReadPre failure (#262)")
    end,
  })

  pcall(function()
    diff._setup_blocking_diff({
      old_file_path = old_file,
      new_file_path = old_file,
      new_file_contents = "# proposed by Claude\n\nNEW line one\nline two\n",
      tab_name = "✻ [Claude Code] issue262.md ⧉",
    }, function() end)
  end)

  pcall(vim.api.nvim_del_augroup_by_id, grp)
  os.remove(old_file)

  local after = vim.fn.tabpagenr("$")
  -- Keep the message to ONE short line so it doesn't trip the hit-enter prompt.
  vim.api.nvim_echo({
    {
      ("repro262: tabs %d -> %d%s"):format(before, after, after > before and "  <<< STRANDED TAB" or "  (no leak)"),
      after > before and "ErrorMsg" or "MoreMsg",
    },
  }, false, {})
end

vim.api.nvim_create_user_command("ReproStrandTab", repro_strand_tab, { desc = "Repro #262 stranded tab" })
vim.keymap.set("n", "<leader>x", repro_strand_tab, { desc = "Repro #262 stranded tab" })

-- Success-path probe: open a real diff in a new tab with NO injected error. The
-- fix must NOT close this tab (the error-branch tabclose should only fire on
-- failure). Used during /verify to confirm the change didn't over-close.
vim.api.nvim_create_user_command("ReproOpenDiffOk", function()
  local diff = require("claudecode.diff")
  diff.setup({
    diff_opts = { layout = "vertical", open_in_new_tab = true, on_new_file_reject = "keep_empty" },
    terminal = {},
  })
  local before = vim.fn.tabpagenr("$")
  local old_file = vim.fn.tempname() .. "_ok262.md"
  local fh = io.open(old_file, "w")
  fh:write("# original\n\nline one\nline two\n")
  fh:close()
  local ok_setup = pcall(function()
    diff._setup_blocking_diff({
      old_file_path = old_file,
      new_file_path = old_file,
      new_file_contents = "# proposed by Claude\n\nNEW line one\nline two\n",
      tab_name = "✻ [Claude Code] ok262.md ⧉",
    }, function() end)
  end)
  os.remove(old_file)
  local after = vim.fn.tabpagenr("$")
  vim.api.nvim_echo({
    {
      ("ReproOpenDiffOk: ok=%s  tabs %d -> %d"):format(tostring(ok_setup), before, after),
      ok_setup and "MoreMsg" or "ErrorMsg",
    },
  }, false, {})
end, { desc = "Open a successful diff in a new tab (#262 success-path probe)" })

vim.api.nvim_create_user_command("ReproReset", function()
  require("claudecode.diff")._cleanup_all_active_diffs("repro reset")
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.api.nvim_echo({ { ("ReproReset: tabs=%d"):format(vim.fn.tabpagenr("$")), "MoreMsg" } }, false, {})
end, { desc = "Reset repro layout to a single tab" })
