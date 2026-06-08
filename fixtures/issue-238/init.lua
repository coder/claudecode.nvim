-- Repro fixture for issue #238: "[BUG] Rejecting with `:q` does not work".
--
-- Scenario this fixture is built to demonstrate:
--   1. claudecode.nvim is configured exactly like the reporter:
--        - terminal.provider  = "none"   (Claude runs in an *external* terminal,
--          e.g. sidekick.nvim — Neovim manages no terminal of its own)
--        - diff_opts.open_in_new_tab = true
--        - diff_opts.layout          = "vertical"
--   2. Claude opens a diff via the `openDiff` MCP tool. It lands in a NEW tab
--      with the original file on the left and the proposed buffer on the right.
--   3. The user tries to REJECT the change with `:q` (as the README documents:
--      "Reject: `:q` or <leader>ad").
--   4. EXPECTED: the diff is rejected (Claude is told DIFF_REJECTED) and the
--      tab closes.
--      ACTUAL (the bug): `:q` only closes the proposed window; the buffer is
--      merely *hidden* (it is a scratch buffer => bufhidden=hide), so none of
--      the BufDelete/BufUnload/BufWipeout autocmds that drive rejection fire.
--      The diff stays "pending" forever and the tab lingers.
--
-- This fixture mirrors `remote-diff` but uses the reporter's exact config and
-- exposes a `:DiffStateFile` command that writes a machine-readable JSON
-- snapshot (window/tab counts, per-diff status, and the proposed buffer's
-- bufhidden) so automation can assert on the bug without scraping the screen.
--
-- Usage (from repo root):
--   source fixtures/nvim-aliases.sh
--   vv issue-238 example/target.txt
--   #   or: NVIM_APPNAME=issue-238 XDG_CONFIG_HOME=fixtures nvim fixtures/issue-238/example/target.txt
--
-- Then drive the MCP side (play the role of Claude) with:
--   scripts/repro_issue_238.sh

local config_dir = vim.fn.stdpath("config")
local repo_root = vim.fn.fnamemodify(config_dir, ":h:h")
vim.opt.rtp:prepend(repo_root)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

-- The reporter's exact config uses open_in_new_tab = true, but the underlying
-- bug is not tab-specific. Set REPRO238_NEW_TAB=0 to probe the default
-- (same-tab) layout and confirm `:q` rejection is broken there too.
local open_in_new_tab = os.getenv("REPRO238_NEW_TAB") ~= "0"

claudecode.setup({
  auto_start = false,
  -- Quiet logging keeps the diff UI clean for screenshots / automation and
  -- avoids the hit-enter prompt that long :messages can trigger.
  log_level = "warn",
  terminal = {
    -- The reporter uses sidekick.nvim to run Claude in an external terminal,
    -- so claudecode itself manages no terminal: provider = "none".
    provider = "none",
  },
  diff_opts = {
    layout = "vertical",
    open_in_new_tab = open_in_new_tab,
    keep_terminal_focus = false,
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
  if started_or_err or port_or_err == "Already running" then
    return true
  end
  vim.notify("ClaudeCode failed to start: " .. tostring(port_or_err), vim.log.levels.ERROR)
  return false
end

ensure_started()

-- Build a snapshot of everything that matters for this bug.
local function diff_state()
  local diff = require("claudecode.diff")
  local active = diff._get_active_diffs()

  local diffs = {}
  for tab_name, data in pairs(active) do
    local proposed_bufhidden = nil
    if data.new_buffer and vim.api.nvim_buf_is_valid(data.new_buffer) then
      proposed_bufhidden = vim.api.nvim_buf_get_option(data.new_buffer, "bufhidden")
    end
    diffs[#diffs + 1] = {
      tab_name = tab_name,
      status = data.status or "?",
      created_new_tab = data.created_new_tab or false,
      new_buffer = data.new_buffer,
      new_buffer_valid = data.new_buffer and vim.api.nvim_buf_is_valid(data.new_buffer) or false,
      new_buffer_loaded = data.new_buffer and vim.api.nvim_buf_is_loaded(data.new_buffer) or false,
      proposed_bufhidden = proposed_bufhidden,
    }
  end
  table.sort(diffs, function(a, b)
    return tostring(a.tab_name) < tostring(b.tab_name)
  end)

  return {
    windows = #vim.api.nvim_list_wins(),
    tabpages = #vim.api.nvim_list_tabpages(),
    active_diffs = #diffs,
    diffs = diffs,
  }
end

-- Human-readable variant.
vim.api.nvim_create_user_command("DiffState", function()
  local s = diff_state()
  local lines = {
    ("windows=%d  tabpages=%d  active_diffs=%d"):format(s.windows, s.tabpages, s.active_diffs),
  }
  for _, d in ipairs(s.diffs) do
    lines[#lines + 1] = ("  [%s] new_tab=%s bufhidden=%s loaded=%s  %s"):format(
      d.status,
      tostring(d.created_new_tab),
      tostring(d.proposed_bufhidden),
      tostring(d.new_buffer_loaded),
      d.tab_name
    )
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "Show window/tab count + active claudecode diffs" })

-- Scriptable variant: writes the state as JSON to a file so external automation
-- can assert on it without scraping the message area.
vim.api.nvim_create_user_command("DiffStateFile", function(opts)
  local path = opts.args ~= "" and opts.args or (vim.fn.stdpath("cache") .. "/diff_state.json")
  local s = diff_state()
  vim.fn.writefile({ vim.json.encode(s) }, path)
end, { nargs = "?", desc = "Write window/diff state as JSON to a file" })

vim.keymap.set("n", "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", { desc = "Accept diff" })
vim.keymap.set("n", "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", { desc = "Deny diff" })
vim.keymap.set("n", "<leader>as", "<cmd>DiffState<cr>", { desc = "Show diff state" })
