-- Live (TUI) fixture for issue #228 — run a real Neovim and watch the FIX:
--   * provider="none" + focus_after_send=true emits a one-time warning at setup, and
--   * a `User ClaudeCodeSendComplete` autocmd fires on every connected :ClaudeCodeSend,
--     which this fixture hooks to prove the event (the focus_after_send option itself
--     still cannot focus a Claude session running outside Neovim — that's expected).
-- The websocket connection is STUBBED so the real :ClaudeCodeSend path runs with no CLI.
--
-- Usage (from repo root):
--   nvim -u fixtures/issue-228/live.lua fixtures/issue-228/sample.txt
--
-- Then either:
--   * visually select a few lines and run  :'<,'>ClaudeCodeSend   (the real path), or
--   * run  :Issue228Probe                  (deterministic before/after report)
-- Expect: focus stays on the sample buffer (focus_after_send is inert for "none"), and
-- a "ClaudeCodeSendComplete fired" message appears (the new hook). :messages also shows
-- the one-time setup warning.

local script_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ":h:h:h")
vim.opt.runtimepath:prepend(repo_root)

vim.g.mapleader = " "
vim.o.number = true
vim.o.laststatus = 2

local claudecode = require("claudecode")
claudecode.setup({
  auto_start = false,
  log_level = "warn", -- the #228 setup warning is WARN level
  track_selection = true, -- required for the visual :ClaudeCodeSend path
  focus_after_send = true, -- the option under test (inert for provider="none")
  terminal = { provider = "none" }, -- triggers the #228 warning + makes focus a no-op
})

-- ---- Stub a connected Claude so send_at_mention takes the "connected" branch ----
local server_init = require("claudecode.server.init")
server_init.get_status = function()
  return { running = true, client_count = 1 }
end
claudecode.state.server = {
  _fake = true,
  stop = function()
    return true
  end,
  broadcast = function()
    return true
  end,
}
claudecode._broadcast_at_mention = function(file_path, s, e)
  vim.notify(("(stub) broadcast @%s:%s-%s"):format(file_path, tostring(s), tostring(e)), vim.log.levels.INFO)
  return true, nil, { file_path = file_path, start_line = s, end_line = e }
end

-- start() normally enables selection tracking; we skipped it, so enable directly
-- so the real visual :ClaudeCodeSend path works against the stubbed server.
require("claudecode.selection").enable(claudecode.state.server, 50)

-- ---- The #228 (b) hook: prove the event fires (this is what an external-terminal
-- ---- user would use to run e.g. `tmux select-pane`). ----
vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("Issue228Demo", { clear = true }),
  pattern = "ClaudeCodeSendComplete",
  callback = function(ev)
    local d = ev.data or {}
    vim.notify(
      ("ClaudeCodeSendComplete fired: file=%s lines=%s-%s"):format(
        tostring(d.file_path),
        tostring(d.start_line),
        tostring(d.end_line)
      ),
      vim.log.levels.INFO
    )
  end,
})

-- ---- Deterministic probe: report focus/window state before and after a send ----
local function snapshot()
  return {
    win = vim.api.nvim_get_current_win(),
    buf = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
    wins = vim.fn.winnr("$"),
  }
end

vim.api.nvim_create_user_command("Issue228Probe", function()
  local before = snapshot()
  local file = vim.api.nvim_buf_get_name(0)
  claudecode.send_at_mention(file, 0, 2, "Issue228Probe")
  local after = snapshot()
  local moved = (before.win ~= after.win) or (before.wins ~= after.wins)
  local lines = {
    "issue #228 probe (provider=none, focus_after_send=true)",
    ("  before: win=%d buf=%s wins=%d"):format(before.win, before.buf, before.wins),
    ("  after : win=%d buf=%s wins=%d"):format(after.win, after.buf, after.wins),
    ("  focus moved by focus_after_send? %s   (expected: NO)"):format(tostring(moved)),
    "  (a ClaudeCodeSendComplete message above proves the new hook fired)",
  }
  vim.notify(table.concat(lines, "\n"), moved and vim.log.levels.WARN or vim.log.levels.INFO)
end, { desc = "Issue #228: send and report focus + that the event fired" })

-- short, single-line banner (a long one trips the hit-enter prompt under automation)
vim.schedule(function()
  vim.notify("issue228 fixture ready — run :Issue228Probe or :'<,'>ClaudeCodeSend", vim.log.levels.INFO)
end)
