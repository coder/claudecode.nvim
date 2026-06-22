-- Repro fixture for issue #289:
--   "[BUG] ClaudeCodeSend misclassifies regular buffers as tree buffers when
--    file path contains 'neo-tree' or 'NvimTree'"
--
-- Root cause (lua/claudecode/init.lua, handle_send_normal + handle_send_visual):
-- a buffer is classified as a file-explorer ("tree") buffer not only by its
-- FILETYPE but also by a substring match against its BUFFER NAME:
--
--     local is_tree_buffer = current_ft == "NvimTree"
--       or current_ft == "neo-tree"
--       or ...
--       or string.match(current_bufname, "neo%-tree")    -- false positive
--       or string.match(current_bufname, "NvimTree")     -- false positive
--       or string.match(current_bufname, "minifiles://")
--
-- So a perfectly ordinary file whose PATH happens to contain one of those
-- substrings (e.g. a Neovim plugin spec at lua/plugins/_neo-tree_.lua, or any
-- file under a directory called nvim-tree-config/) is mistaken for a tree.
--
-- Symptom, visual path (the README-default `<leader>as` keymap uses
-- `<cmd>ClaudeCodeSend<cr>`, which KEEPS the buffer in visual mode):
--   1. wrapper sees mode == "v" -> exit_visual_and_schedule(visual_handler)
--   2. capture_visual_selection_data() returns nil (get_tree_state() is nil for
--      a real `lua` buffer) and <Esc> is fed, dropping us into normal mode
--   3. handle_send_visual: is_tree_buffer == true (bufname match) -> takes the
--      tree branch -> get_files_from_visual_selection(nil) -> validate_visual_mode()
--      now fails because the mode is "n" -> logs:
--        ClaudeCodeSend_visual->TreeAdd: Not in visual mode (current mode: n)
--   ...and nothing is ever sent to Claude.
--
-- Symptom, normal/range path (`:'<,'>ClaudeCodeSend`): mode is "n", so
-- handle_send_normal runs; is_tree_buffer is still true, so it calls
-- integrations.get_selected_files_from_tree(), which fails with:
--   ClaudeCodeSend->TreeAdd: Not in a supported tree buffer (current filetype: lua)
--
-- A control file whose path has NONE of those substrings works correctly.
--
-- Usage (from repo root):
--   source fixtures/nvim-aliases.sh
--   vv issue-289 'lua/plugins/_neo-tree_.lua'   # AFFECTED (path has 'neo-tree')
--   vv issue-289 'lua/regular_plugin.lua'       # CONTROL (no substring)
-- or directly:
--   NVIM_APPNAME=issue-289 XDG_CONFIG_HOME=fixtures \
--     nvim fixtures/issue-289/lua/plugins/_neo-tree_.lua
--
-- Commands provided for automation:
--   :ReproDump [path]   write captured ClaudeCode notifications as JSON to `path`
--                       (defaults to stdpath('cache')/issue289_notifications.json)
--   :ReproClear         clear the captured-notification buffer

local config_dir = vim.fn.stdpath("config")
local repo_root = vim.fn.fnamemodify(config_dir, ":h:h")
vim.opt.rtp:prepend(repo_root)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- A little extra command height keeps long error notifications from triggering
-- the blocking hit-enter prompt while driving Neovim with agent-tty.
vim.o.cmdheight = 3
vim.o.more = false

-- Capture every ClaudeCode notification so automation can assert on it without
-- scraping the screen. We still forward to the original handler so the error is
-- also visible in a screenshot.
_G._repro_notifications = {}
local original_notify = vim.notify
vim.notify = function(msg, level, opts)
  table.insert(_G._repro_notifications, {
    message = tostring(msg),
    level = level,
    title = opts and opts.title or nil,
  })
  return original_notify(msg, level, opts)
end

local ok, claudecode = pcall(require, "claudecode")
assert(ok, "Failed to load claudecode.nvim from repo root: " .. tostring(claudecode))

claudecode.setup({
  auto_start = false,
  -- ERROR notifications fire regardless of log_level; "info" keeps the rest quiet.
  log_level = "info",
  -- No in-editor terminal needed to reproduce the misclassification.
  terminal = {
    provider = "none",
  },
})

-- Best-effort: start the server so the CONTROL path can actually queue an
-- at-mention. The bug itself does NOT require a running server or a connected
-- client -- the misclassification happens before any server interaction.
pcall(function()
  claudecode.start(false)
end)

-- README-default visual keymap: this is the exact mapping the docs recommend
-- and the one the reporter uses. `<cmd>...<cr>` PRESERVES visual mode, which is
-- what routes the request into the (buggy) visual tree-extraction path.
vim.keymap.set("v", "<leader>as", "<cmd>ClaudeCodeSend<cr>", { desc = "Send to Claude" })

vim.api.nvim_create_user_command("ReproDump", function(opts)
  local path = opts.args ~= "" and opts.args or (vim.fn.stdpath("cache") .. "/issue289_notifications.json")
  vim.fn.writefile({ vim.json.encode(_G._repro_notifications) }, path)
  original_notify("ReproDump -> " .. path .. " (" .. #_G._repro_notifications .. " notifications)", vim.log.levels.INFO)
end, { nargs = "?", desc = "Write captured ClaudeCode notifications as JSON" })

vim.api.nvim_create_user_command("ReproClear", function()
  _G._repro_notifications = {}
end, { desc = "Clear captured ClaudeCode notifications" })

-- Diagnostic snapshot: records how the CURRENT buffer would be classified so
-- automation can assert on the misclassification directly (no screen-scraping).
vim.api.nvim_create_user_command("ReproState", function(opts)
  local path = opts.args ~= "" and opts.args or (vim.fn.stdpath("cache") .. "/issue289_state.json")
  local buf = 0
  local ft = vim.bo[buf].filetype
  local bufname = vim.api.nvim_buf_get_name(buf)
  -- `is_tree_buffer` mirrors the plugin's CURRENT predicate (post-#289):
  -- filetype only. On the fixed plugin, running this in `_neo-tree_.lua` reports
  -- is_tree_buffer=false, i.e. the file is correctly treated as a normal buffer.
  local matches_filetype = ft == "NvimTree" or ft == "neo-tree" or ft == "oil" or ft == "minifiles" or ft == "netrw"
  -- Legacy pre-#289 signal: the buffer-NAME substring match that USED to also
  -- flip is_tree_buffer to true (the root cause of #289). Reported for
  -- diagnostics so the fixture still shows why ordinary files misfired before
  -- the fix: legacy_path_substring_match=true while is_tree_buffer=false means
  -- "this file would have been misclassified by the old code".
  local legacy_path_substring_match = (string.match(bufname, "neo%-tree") ~= nil)
    or (string.match(bufname, "NvimTree") ~= nil)
    or (string.match(bufname, "minifiles://") ~= nil)
  local state = {
    filetype = ft,
    bufname = bufname,
    matches_filetype = matches_filetype,
    legacy_path_substring_match = legacy_path_substring_match,
    is_tree_buffer = matches_filetype,
    has_send_command = vim.fn.exists(":ClaudeCodeSend") == 2,
    server_running = (function()
      local ok_cc, cc = pcall(require, "claudecode")
      return ok_cc and cc.state and cc.state.server ~= nil or false
    end)(),
  }
  vim.fn.writefile({ vim.json.encode(state) }, path)
  original_notify("ReproState -> " .. path, vim.log.levels.INFO)
end, { nargs = "?", desc = "Write current-buffer tree-classification state as JSON" })
