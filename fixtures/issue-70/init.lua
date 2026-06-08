-- Fixture for issue #70:
--   "[BUG] Sending files, current buffer, or lines to claude doesn't work."
--   symptom: [ClaudeCode] [queue] [ERROR] Connection timeout - clearing N queued @ mentions
--   https://github.com/coder/claudecode.nvim/issues/70
--
-- The symptom is downstream of ONE thing: the Claude CLI that the plugin launches
-- never opens a WebSocket connection back to the plugin's server, so every queued
-- @ mention sits in the queue until `connection_timeout` (default 10s) elapses and
-- the queue is cleared with the error above.
--
-- This fixture launches the REAL plugin with the native terminal provider so the
-- Claude CLI runs inside Neovim. Run it with a proxy set in the environment but no
-- `no_proxy` exclusion for localhost to reproduce the dominant, currently-live root
-- cause (see fixtures/issue-70/README.md):
--
--   export http_proxy=http://127.0.0.1:1 all_proxy=http://127.0.0.1:1
--   unset no_proxy NO_PROXY
--   ISSUE70_LOG=/tmp/issue70.log \
--     NVIM_APPNAME=issue-70 XDG_CONFIG_HOME="$PWD/fixtures" \
--     nvim fixtures/issue-70/sample.txt
--   :Issue70Send        " launches Claude (cannot connect through the dead proxy)
--   " ...wait ~10s...    -> the Connection timeout ERROR notification appears
--
-- With NO proxy (or with `no_proxy=localhost,127.0.0.1,::1`) the same steps connect
-- cleanly and the @ mention is delivered -- that contrast is the whole bug.

local config_dir = vim.fn.stdpath("config")
local repo_root = vim.fn.fnamemodify(config_dir, ":h:h")
vim.opt.rtp:prepend(repo_root)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
vim.o.laststatus = 2

-- Tee every vim.notify (the plugin logs through it) to ISSUE70_LOG so the
-- "Connection timeout" ERROR can be asserted deterministically from a script,
-- not just scraped off the TUI.
local log_path = vim.env.ISSUE70_LOG
if log_path and log_path ~= "" then
  local orig_notify = vim.notify
  vim.notify = function(msg, level, opts) -- luacheck: ignore
    pcall(function()
      local fh = io.open(log_path, "a")
      if fh then
        fh:write(("[notify lvl=%s] %s\n"):format(tostring(level), tostring(msg)))
        fh:close()
      end
    end)
    return orig_notify(msg, level, opts)
  end
end

local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

claudecode.setup({
  auto_start = true, -- start the WebSocket server immediately
  log_level = "debug",
  terminal = {
    provider = "native", -- run Claude inside Neovim so one PTY drives everything
    auto_close = false,
  },
  -- defaults: connection_timeout = 10000, queue_timeout = 5000
})

local banner = {
  "claudecode.nvim -- issue #70 reproduction fixture",
  "",
  "Symptom: [ClaudeCode] [queue] [ERROR] Connection timeout - clearing N queued @ mentions",
  "",
  "Run :Issue70Send (or <leader>s) to launch Claude and queue this file as an",
  "@ mention. If the launched Claude cannot connect back to the plugin's server",
  "(e.g. a proxy is set with no localhost exclusion), the queue clears after",
  "~10s with the Connection timeout ERROR.",
  "",
  "Server port: (see :ClaudeCodeStatus)",
}
vim.api.nvim_buf_set_lines(0, 0, -1, false, banner)
vim.bo.modifiable = false
vim.bo.modified = false

-- Queue THIS fixture's sample file as an @ mention via the real public API.
local function issue70_send()
  local sample = repo_root .. "/fixtures/issue-70/sample.txt"
  if vim.fn.filereadable(sample) == 0 then
    sample = vim.fn.expand("%:p")
  end
  local okk, err = require("claudecode").send_at_mention(sample, nil, nil, "issue70")
  vim.api.nvim_echo({
    {
      ("Issue70Send: queued %s (ok=%s%s)"):format(
        vim.fn.fnamemodify(sample, ":t"),
        tostring(okk),
        err and (" err=" .. err) or ""
      ),
      "MoreMsg",
    },
  }, false, {})
end

vim.api.nvim_create_user_command("Issue70Send", issue70_send, { desc = "Repro #70: queue sample.txt as @ mention" })
vim.keymap.set("n", "<leader>s", issue70_send, { desc = "Repro #70 send" })
