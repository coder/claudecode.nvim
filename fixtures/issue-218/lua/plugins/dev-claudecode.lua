-- claudecode.nvim (local checkout) configured exactly like the reporter's
-- repro.lua for issue #218, plus a deterministic, Claude-free trigger
-- (:Repro218) that recreates the precise state that crashes Neovim.
--
-- Root cause (verified): accepting (:w) a NEW-file *markdown* diff that was
-- opened in a NEW TAB (diff_opts.open_in_new_tab = true) tears the diff down via
-- diff.close_diff_by_tab_name -> _cleanup_diff_state, which runs `:tabclose` on
-- the tab whose windows are STILL in diff mode. When render-markdown.nvim is
-- attached to that markdown buffer and the Claude terminal is open in the other
-- tab, that `:tabclose` abnormally terminates Neovim (SIGSEGV / exit 139 for the
-- reporter). Removing render-markdown, or turning diff mode off before the
-- teardown (the reporter's `diffoff` workaround), avoids it.
--
-- :Repro218 reproduces this with NO real Claude needed: it opens a harmless
-- Claude *terminal* (a sleeping process) so the layout matches real usage, then
-- opens the new-tab markdown diff through the SAME coroutine machinery the
-- openDiff MCP tool uses (diff.open_diff_blocking), wiring the deferred response
-- so that accepting the diff simulates Claude writing the file and sending
-- close_tab. Focus is left in the proposed pane: just press `:w` to crash.
--
-- We load eagerly (lazy = false) so the diff module is configured at startup.
return {
  "coder/claudecode.nvim",
  dir = vim.g.claudecode_dev_dir,
  dependencies = { "folke/snacks.nvim" },
  lazy = false,
  keys = {
    { "<C-,>", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
  },
  ---@type PartialClaudeCodeConfig
  opts = {
    terminal = { split_side = "left", split_width_percentage = 0.5 },
    diff_opts = { open_in_new_tab = true, hide_terminal_in_new_tab = true },
  },
  config = function(_, opts)
    require("claudecode").setup(opts)

    -- Markdown payload with the structures render-markdown attaches to (headings,
    -- fenced code, lists, blockquotes, tables).
    local function payload()
      return table.concat({
        "# Issue 218 Repro",
        "",
        "This is a **new** markdown file proposed by Claude.",
        "",
        "## Section heading",
        "",
        "- item one",
        "- item two",
        "  - nested",
        "",
        "```lua",
        "local x = 1",
        "print(x)",
        "```",
        "",
        "> A blockquote for render-markdown to decorate.",
        "",
        "| col a | col b |",
        "| ----- | ----- |",
        "| 1     | 2     |",
        "",
        "1. first",
        "2. second",
        "",
      }, "\n") .. "\n"
    end

    -- Open a harmless Claude *terminal* (a sleeping process) without stealing
    -- focus, so the window layout matches real usage. The crash only reproduces
    -- when the Claude terminal is present in the original tab.
    local function ensure_dummy_terminal()
      local term = require("claudecode.terminal")
      if term.get_active_terminal_bufnr and term.get_active_terminal_bufnr() then
        return -- a terminal is already open (e.g. real :ClaudeCode); leave it
      end
      -- Override the launched command so no real Claude/API is needed.
      term.defaults.terminal_cmd = "sh -c 'while :; do sleep 3600; done'"
      pcall(vim.cmd, "ClaudeCodeStart")
      pcall(function()
        term.toggle_open_no_focus()
      end)
    end

    -- Recreate the exact openDiff flow the server runs: open_diff_blocking inside
    -- a coroutine, with _G.claude_deferred_responses wired so the :w resolution
    -- resumes the coroutine and then simulates Claude (write the file to disk,
    -- then send close_tab via close_diff_by_tab_name on a later tick).
    local function repro_218()
      ensure_dummy_terminal()
      local diff = require("claudecode.diff")
      local new_file = vim.fn.tempname() .. "_issue218.md"
      pcall(os.remove, new_file) -- ensure it does not exist => is_new_file = true
      local contents = payload()
      local tab_name = "✻ [Claude Code] issue218.md ⧉"

      _G.claude_deferred_responses = _G.claude_deferred_responses or {}
      local co = coroutine.create(function()
        return diff.open_diff_blocking(new_file, new_file, contents, tab_name, nil)
      end)
      _G.claude_deferred_responses[tostring(co)] = function()
        -- Claude received FILE_SAVED: write the file, then send close_tab.
        vim.schedule(function()
          local fh = io.open(new_file, "w")
          if fh then
            fh:write(contents)
            fh:close()
          end
          vim.schedule(function()
            pcall(diff.close_diff_by_tab_name, tab_name)
          end)
        end)
      end

      -- Defer the open so the terminal split settles first, then resume the
      -- coroutine (which sets up the diff) and leave focus in the proposed pane.
      vim.schedule(function()
        coroutine.resume(co)
        vim.schedule(function()
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            local name = vim.api.nvim_buf_get_name(b)
            if name:match("proposed") and vim.bo[b].buftype == "acwrite" then
              local win = vim.fn.win_findbuf(b)[1]
              if win then
                vim.api.nvim_set_current_win(win)
              end
            end
          end
          vim.api.nvim_echo({
            {
              "Repro218 ready. Press :w in the proposed pane to accept (Neovim crashes — issue #218).",
              "WarningMsg",
            },
          }, false, {})
        end)
      end)
    end

    vim.api.nvim_create_user_command("Repro218", repro_218, {
      desc = "Set up the issue #218 crash: open a NEW-file markdown diff in a new tab; then :w",
    })

    vim.api.nvim_create_user_command("Repro218Reset", function()
      require("claudecode.diff")._cleanup_all_active_diffs("repro reset")
      vim.cmd("silent! tabonly!")
      vim.cmd("silent! only!")
      vim.cmd("silent! enew!")
    end, { desc = "Reset the #218 repro layout" })
  end,
}
