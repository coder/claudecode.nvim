-- Reproduction / verification for issue #289:
--   "[BUG] ClaudeCodeSend misclassifies regular buffers as tree buffers when
--    file path contains 'neo-tree' or 'NvimTree'"
--   https://github.com/coder/claudecode.nvim/issues/289
--
-- The bug: handle_send_normal and handle_send_visual (lua/claudecode/init.lua)
-- decide whether the current buffer is a file-explorer ("tree") buffer using
-- BOTH the filetype AND a substring match against the buffer NAME:
--
--     local is_tree_buffer = current_ft == "NvimTree"
--       or current_ft == "neo-tree" or current_ft == "oil"
--       or current_ft == "minifiles" or current_ft == "netrw"
--       or string.match(current_bufname, "neo%-tree")    -- false positive
--       or string.match(current_bufname, "NvimTree")     -- false positive
--       or string.match(current_bufname, "minifiles://")
--
-- So an ordinary `lua` file whose PATH merely contains "neo-tree" / "NvimTree"
-- (e.g. a plugin spec named `_neo-tree_.lua`) is treated as a tree buffer, and
-- a visual send is routed into tree-extraction instead of the normal selection
-- path. Result, depending on how the command is invoked:
--   * `:'<,'>ClaudeCodeSend`        -> ClaudeCodeSend->TreeAdd: Not in a
--                                       supported tree buffer (current filetype: lua)
--   * <leader>as (`<cmd>...<cr>`)   -> ClaudeCodeSend_visual->TreeAdd: Not in
--                                       visual mode (current mode: n)
-- ...and nothing is sent to Claude.
--
-- This script drives the REAL `:ClaudeCodeSend` user command (registered by
-- claudecode.setup) against both an affected buffer and a control buffer, with
-- no WebSocket / Claude CLI needed. It reproduces the bug on unfixed code and
-- will verify a fix.
--
-- Run from the repo root:
--   nvim --headless -u NONE -l scripts/repro_issue_289.lua
--
-- Exit code: 1 if the misclassification is observed (#289 reproduced), 0 if the
-- affected buffer behaves like the control (fixed). A detailed verdict is
-- printed either way.

vim.g.mapleader = " " -- must be set before the <leader> mapping is created
vim.g.maplocalleader = "\\"

local script_path = debug.getinfo(1, "S").source:sub(2)
local repo_root = vim.fn.fnamemodify(script_path, ":h:h")
vim.opt.rtp:prepend(repo_root)

local function out(msg)
  io.stdout:write(msg .. "\n")
end

-- Capture (and swallow) ClaudeCode notifications so we can assert on the error
-- text without it cluttering the output.
local captured = {}
vim.notify = function(msg, level, opts)
  table.insert(captured, { message = tostring(msg), level = level, title = opts and opts.title or nil })
end
-- The logger wraps notify in vim.schedule; nvim_echo is used for lower levels.
local orig_echo = vim.api.nvim_echo
vim.api.nvim_echo = function() end

local cc = require("claudecode")
cc.setup({
  auto_start = false,
  log_level = "info",
  terminal = { provider = "none" },
})
-- A server object only matters for the *downstream* send; the misclassification
-- happens before that. Provide a stub so the "correct" path can complete.
cc.state.server = cc.state.server or {
  broadcast = function()
    return true
  end,
}

-- Spy on the two mutually-exclusive downstream paths.
local selection = require("claudecode.selection")
local sent = { count = 0, args = nil }
selection.send_at_mention_for_visual_selection = function(l1, l2)
  sent.count = sent.count + 1
  sent.args = { l1, l2 }
  return true
end

local integrations = require("claudecode.integrations")
local tree = { count = 0 }
integrations.get_selected_files_from_tree = function()
  tree.count = tree.count + 1
  -- Mirror the real error text for a non-tree filetype.
  return {}, "Not in a supported tree buffer (current filetype: lua)"
end

-- README-default visual mapping (the reporter's mapping). `<cmd>...<cr>` keeps
-- visual mode, which routes into handle_send_visual.
vim.keymap.set("v", "<leader>as", "<cmd>ClaudeCodeSend<cr>")

local LUA_LINES = {
  "return {",
  '  "nvim-neo-tree/neo-tree.nvim",',
  "  branch = 'v3.x',",
  "  config = function() end,",
  "}",
}

local function open_buffer(path)
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, LUA_LINES)
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return buf
end

local function first_treeadd_error()
  for _, n in ipairs(captured) do
    if n.message:match("TreeAdd") then
      return n.message
    end
  end
  return nil
end

-- Exercise both invocation styles against one buffer.
---@return table result {range_sent, range_tree, range_err, visual_err}
local function exercise(path)
  open_buffer(path)

  -- (1) Range path: `:1,3ClaudeCodeSend` (mode is normal -> handle_send_normal)
  captured, sent.count, tree.count = {}, 0, 0
  pcall(function()
    vim.cmd("1,3ClaudeCodeSend")
  end)
  vim.wait(60)
  local range_sent = sent.count
  local range_tree = tree.count
  local range_err = first_treeadd_error()

  -- (2) Visual path: real visual selection + <leader>as (-> handle_send_visual)
  captured, sent.count, tree.count = {}, 0, 0
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local keys = vim.api.nvim_replace_termcodes("Vjj as", true, false, true)
  pcall(function()
    vim.api.nvim_feedkeys(keys, "x", false)
  end)
  vim.wait(120)
  local visual_err = first_treeadd_error()
  local visual_sent = sent.count

  return {
    range_sent = range_sent,
    range_tree = range_tree,
    range_err = range_err,
    visual_err = visual_err,
    visual_sent = visual_sent,
  }
end

out("== issue #289 reproduction (path-substring tree misclassification) ==")
out(("Neovim: %s"):format(tostring(vim.version())))

local AFFECTED = vim.fn.tempname() .. "/lua/plugins/_neo-tree_.lua"
local CONTROL = vim.fn.tempname() .. "/lua/plugins/regular_plugin.lua"

local affected = exercise(AFFECTED)
local control = exercise(CONTROL)

local function report(label, path, r)
  out(("\n[%s]  %s"):format(label, path))
  out(
    ("  range  : sent=%d tree_extract=%d  %s"):format(
      r.range_sent,
      r.range_tree,
      r.range_err and ("ERROR: " .. r.range_err:gsub("%s+", " ")) or "(no TreeAdd error)"
    )
  )
  out(
    ("  visual : sent=%d  %s"):format(
      r.visual_sent,
      r.visual_err and ("ERROR: " .. r.visual_err:gsub("%s+", " ")) or "(no TreeAdd error)"
    )
  )
end

report("AFFECTED", AFFECTED, affected)
report("CONTROL ", CONTROL, control)

-- Verdict.
-- Bug present iff the AFFECTED buffer is misrouted into tree extraction on the
-- (deterministic) range path while the CONTROL buffer is sent correctly.
local affected_misrouted = (affected.range_sent == 0 and affected.range_tree > 0)
local affected_visual_err = (affected.visual_err ~= nil)
local control_ok = (control.range_sent == 1 and control.range_tree == 0 and control.range_err == nil)

out("\n== verdict ==")
out(("  control behaves correctly      : %s"):format(tostring(control_ok)))
out(("  affected misrouted (range)     : %s"):format(tostring(affected_misrouted)))
out(("  affected errored (visual path) : %s"):format(tostring(affected_visual_err)))

if affected_misrouted and control_ok then
  out("\nRESULT: #289 REPRODUCED -- a `lua` buffer whose path contains 'neo-tree'")
  out("        is misclassified as a tree buffer and the send fails.")
  vim.cmd("cquit 1")
else
  out("\nRESULT: not reproduced -- affected buffer behaves like the control (fixed).")
  vim.cmd("cquit 0")
end
