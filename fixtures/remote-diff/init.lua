-- Repro fixture for issue #248: "Close diff handled by remote control".
--
-- Scenario this fixture is built to demonstrate:
--   1. Claude opens one or more diffs in Neovim via the `openDiff` MCP tool.
--   2. The user resolves those diffs from *somewhere other than this Neovim*
--      (e.g. Claude "remote control" on a phone), so the diff is never
--      accepted/rejected inside Neovim and no `close_tab` arrives.
--   3. The diff windows stay open in Neovim forever.
--
-- Unlike the generic `repro` fixture this one keeps logging quiet (so the diff
-- UI is clean for screenshots / automation) and exposes a `:DiffState` command
-- that prints how many windows and how many *active* claudecode diffs exist.
--
-- Usage (from repo root):
--   source fixtures/nvim-aliases.sh
--   vv remote-diff            # or: NVIM_APPNAME=remote-diff XDG_CONFIG_HOME=fixtures nvim a.txt
--
-- Then drive the MCP side with scripts/repro_issue_248.sh.

local config_dir = vim.fn.stdpath("config")
local repo_root = vim.fn.fnamemodify(config_dir, ":h:h")
vim.opt.rtp:prepend(repo_root)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

claudecode.setup({
  auto_start = false,
  -- Keep logging quiet so the diff UI is clean for screenshots / automation.
  -- (The generic `repro` fixture uses "debug", which spams the message area and
  -- triggers hit-enter prompts that interfere with TUI automation.)
  log_level = "warn",
  terminal = {
    provider = "native",
    auto_close = false,
  },
  diff_opts = {
    layout = "vertical",
    open_in_new_tab = false,
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

-- Inspection command: how many windows, and how many *active* diffs does the
-- diff module still think are open? This is the heart of the repro: after a
-- remote resolution the windows linger and active_diffs never drains.
local function diff_state()
  local wins = #vim.api.nvim_list_wins()
  local active = require("claudecode.diff")._get_active_diffs()
  local names = {}
  for tab_name, data in pairs(active) do
    names[#names + 1] = ("    [%s] %s"):format(data.status or "?", tab_name)
  end
  table.sort(names)
  local lines = {
    ("windows=%d  active_diffs=%d"):format(wins, #names),
  }
  vim.list_extend(lines, names)
  return lines, wins, #names
end

vim.api.nvim_create_user_command("DiffState", function()
  local lines = diff_state()
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "Show window count + active claudecode diffs" })

-- Scriptable variant: writes the state to a file so external automation can
-- assert on it without scraping the message area.
vim.api.nvim_create_user_command("DiffStateFile", function(opts)
  local path = opts.args ~= "" and opts.args or (vim.fn.stdpath("run") .. "/diff_state.txt")
  local lines = diff_state()
  vim.fn.writefile(lines, path)
end, { nargs = "?", desc = "Write window/diff state to a file" })

vim.keymap.set("n", "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", { desc = "Accept diff" })
vim.keymap.set("n", "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", { desc = "Deny diff" })
vim.keymap.set("n", "<leader>as", "<cmd>DiffState<cr>", { desc = "Show diff state" })
