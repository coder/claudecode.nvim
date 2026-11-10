-- Fixture for issue #285:
--   "[BUG] ClaudeCodeAdd fails when adding a file in a directory with a `$`"
--   https://github.com/coder/claudecode.nvim/issues/285
--
-- The sample tree under fixtures/issue-285/sample/ contains a REAL file whose
-- parent directory is literally named "$post":
--   fixtures/issue-285/sample/src/routes/$post/index.tsx
--
-- :ClaudeCodeAdd and the openFile MCP tool both pass the path through
-- vim.fn.expand(), which substitutes "$post" with the (undefined) env var ->
-- the path becomes ".../src/routes//index.tsx", which does not exist, so the
-- command reports "File or directory does not exist".
--
-- Usage (from repo root):
--   source fixtures/nvim-aliases.sh && vv issue-285
-- The $-path file opens automatically. Then either:
--   * press <leader>x   -> runs :Repro285 (self-contained verdict), or
--   * run :Repro285     -> drives the REAL :ClaudeCodeAdd + openFile on the
--                          $-path file and echoes a one-line PASS/FAIL verdict.
-- For a fully hand-driven check: :ClaudeCodeStart, then
--   :ClaudeCodeAdd <paste the absolute path printed in the banner>   (FAILS), vs
--   :ClaudeCodeAdd %                                                 (works),
-- then read :messages.

local config_dir = vim.fn.stdpath("config")
local repo_root = vim.fn.fnamemodify(config_dir, ":h:h")
vim.opt.rtp:prepend(repo_root)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
vim.o.laststatus = 2

local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

claudecode.setup({
  auto_start = false,
  log_level = "info",
  terminal = { provider = "native", auto_close = false },
})

-- Resolve the real $-path sample file shipped with this fixture.
local sample = repo_root .. "/fixtures/issue-285/sample/src/routes/$post/index.tsx"

-- Open it so the buffer name itself carries the `$` (this is the file a user
-- would be "adding to the buffer"). fnameescape keeps `$` literal for :edit.
vim.cmd("edit " .. vim.fn.fnameescape(sample))

local banner_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(banner_buf, 0, -1, false, {
  "claudecode.nvim -- issue #285 reproduction fixture",
  "",
  "Sample file (exists on disk, parent dir is literally '$post'):",
  "  " .. sample,
  "",
  "Press <leader>x  (or run :Repro285) for a one-line PASS/FAIL verdict.",
  "",
  "Manual check (with the fix applied, both succeed):",
  "  :ClaudeCodeStart",
  "  :ClaudeCodeAdd " .. sample,
  "  :ClaudeCodeAdd %        (current buffer; % is still expanded, not taken literally)",
  "  :messages",
  "",
  "Before this fix, the first form errored with:",
  "  [ClaudeCode] [command] [ERROR] ClaudeCodeAdd: File or directory does",
  "  not exist: .../src/routes//index.tsx   (note the '//' -- $post vanished)",
})
vim.bo[banner_buf].modifiable = false
vim.bo[banner_buf].buftype = "nofile"

-- Capture the plugin logger so the verdict can show the exact error it logs.
local logger = require("claudecode.logger")
local function with_captured_logger(fn)
  local saved = { error = logger.error, debug = logger.debug, warn = logger.warn, info = logger.info }
  local lines = {}
  local function cap(level)
    return function(component, ...)
      local parts = {}
      for _, v in ipairs({ ... }) do
        parts[#parts + 1] = tostring(v)
      end
      lines[#lines + 1] = { level = level, msg = table.concat(parts, " ") }
    end
  end
  logger.error, logger.debug, logger.warn, logger.info = cap("error"), cap("debug"), cap("warn"), cap("info")
  local ok_run, err = pcall(fn)
  logger.error, logger.debug, logger.warn, logger.info = saved.error, saved.debug, saved.warn, saved.info
  return lines, ok_run, err
end

local function last_error(lines)
  for i = #lines, 1, -1 do
    if lines[i].level == "error" then
      return lines[i].msg
    end
  end
  return nil
end

---Drive the REAL :ClaudeCodeAdd and openFile on the $-path sample, then echo a
---one-line verdict. Self-contained: if the integration isn't started, the
---run-state guard is stubbed so the expand()/filereadable() gate is still
---reached (that gate is where #285 lives -- no Claude connection is involved).
local function repro_285()
  local cc = require("claudecode")
  cc.state = cc.state or {}
  local restore_server = false
  if not cc.state.server then
    cc.state.server = { _stub = true }
    restore_server = true
  end
  local saved_send = cc.send_at_mention
  local reached_send = false
  cc.send_at_mention = function()
    reached_send = true
    return true, nil
  end

  local lines = with_captured_logger(function()
    vim.cmd({ cmd = "ClaudeCodeAdd", args = { sample } })
  end)
  local add_err = last_error(lines)

  local open_ok, open_err = pcall(require("claudecode.tools.open_file").handler, {
    filePath = sample,
    makeFrontmost = false,
  })
  local open_msg = type(open_err) == "table" and tostring(open_err.data or open_err.message) or tostring(open_err)

  cc.send_at_mention = saved_send
  if restore_server then
    cc.state.server = nil
  end

  local add_bug = (add_err ~= nil) and not reached_send
  local open_bug = (not open_ok) and open_msg:find("not found", 1, true) ~= nil
  local reproduced = add_bug or open_bug

  local report = {}
  report[#report + 1] = {
    reproduced and "issue #285 REPRODUCED" or "issue #285 FIXED",
    reproduced and "ErrorMsg" or "MoreMsg",
  }
  vim.api.nvim_echo(report, true, {})
  -- Detail lines land in :messages.
  vim.api.nvim_echo({
    { ("  ClaudeCodeAdd : %s"):format(add_err or (reached_send and "accepted (reached send)" or "no error")) },
  }, true, {})
  vim.api.nvim_echo({
    { ("  openFile tool : %s"):format(open_ok and "opened" or open_msg) },
  }, true, {})
end

vim.api.nvim_create_user_command("Repro285", repro_285, { desc = "Repro #285 ($ in path)" })
vim.keymap.set("n", "<leader>x", repro_285, { desc = "Repro #285 ($ in path)" })
