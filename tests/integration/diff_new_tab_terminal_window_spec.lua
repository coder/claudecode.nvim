if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("the diff's terminal window in a diff tab that stays open", function()
    pending("needs a real Neovim")
  end)
  return
end

local helper = require("tests.helpers.new_tab_diff_child")

describe("the diff's terminal window in a diff tab that stays open", function()
  local child = helper.new()

  after_each(child.stop)

  ---The diff is the last tab, as when the user closed the first one, and the cursor is in the diff tab. With
  ---`cursor_in_terminal` the user left the diff tab's terminal in terminal-normal mode first.
  local function open_in_last_tab(layout, start_options, cursor_in_terminal)
    child.start(vim.tbl_extend("force", { layout = layout, show_terminal_again = true }, start_options or {}))
    child.open_diff("a.txt", "first diff")
    if cursor_in_terminal then
      child.focus_terminal_in_tab()
      child.leave_terminal_mode()
    end
    assert.equal(1, child.close_first_tab().tabs)
    child.call([[
      local diff_data = assert(require("claudecode.diff")._get_active_diffs()["first diff"])
      _G.diff_terminal_win = diff_data.terminal_win_in_new_tab
    ]])
  end

  local function terminal_window_is_open()
    return child.call([[return vim.api.nvim_win_is_valid(_G.diff_terminal_win)]])
  end

  for _, layout in ipairs({ "vertical", "unified" }) do
    describe("with layout = " .. layout, function()
      it("starts no insert in the file when an autocmd of the user's starts one in every terminal window", function()
        open_in_last_tab(layout)
        child.call([[vim.cmd("autocmd BufEnter term://* startinsert")]])

        child.close_diff("first diff")
        local state = child.state()

        assert.equal("n", state.mode)
        assert.not_equal("terminal", state.buftype)
        assert.is_true(terminal_window_is_open(), "the terminal stays, so the close opens no terminal window")
      end)

      it("keeps the window of the user's file when a BufLeave autocmd enters it", function()
        open_in_last_tab(layout, nil, true)
        local lines = child.call([[
          vim.fn.writefile({ "one", "two" }, _G.dir .. "/other.txt")
          vim.api.nvim_win_call(_G.diff_terminal_win, function()
            vim.cmd("split " .. vim.fn.fnameescape(_G.dir .. "/other.txt"))
            _G.user_win = vim.api.nvim_get_current_win()
          end)
          _G.user_buf = vim.api.nvim_win_get_buf(_G.user_win)
          vim.api.nvim_buf_set_lines(_G.user_buf, 0, -1, false, { "user changed one", "user kept two" })
          _G.ran = false
          vim.api.nvim_create_autocmd("BufLeave", {
            once = true,
            callback = function()
              _G.ran = true
              vim.api.nvim_set_current_win(_G.user_win)
            end,
          })
          return vim.api.nvim_buf_get_lines(_G.user_buf, 0, -1, false)
        ]])

        child.close_diff("first diff")
        child.state()
        local after = child.call([[
          local valid = vim.api.nvim_win_is_valid(_G.user_win)
          return {
            win_valid = valid,
            shown_buf = valid and vim.api.nvim_win_get_buf(_G.user_win) or -1,
            user_buf = _G.user_buf,
            lines = vim.api.nvim_buf_get_lines(_G.user_buf, 0, -1, false),
            ran = _G.ran,
          }
        ]])

        assert.is_true(after.win_valid)
        assert.equal(after.user_buf, after.shown_buf, "the window of the user's file must keep showing it")
        assert.same(lines, after.lines)
        assert.is_false(after.ran, "no BufLeave may fire: the terminal stays, so the provider has none to show again")
      end)

      it(
        "closes the terminal window and its WinClosed autocmd when the user hid the terminal before the diff",
        function()
          open_in_last_tab(layout, { hide_original_terminal = true })
          local function terminal_window_autocmds()
            return child.call([[
            local pattern = tostring(_G.diff_terminal_win)
            return #vim.api.nvim_get_autocmds({ group = "ClaudeCodeMCPDiff", event = "WinClosed", pattern = pattern })
          ]])
          end
          assert.equal(1, terminal_window_autocmds())

          child.close_diff("first diff")
          local state = child.state()

          assert.equal("n", state.mode)
          assert.is_false(terminal_window_is_open())
          assert.equal(1, child.leftovers().windows)
          assert.equal(0, child.leftovers().handlers)
          assert.equal(0, terminal_window_autocmds(), "the window is gone, so its WinClosed autocmd must go too")
        end
      )

      it("keeps the terminal window when the only other window that shows it is a float parked with hide", function()
        if vim.fn.has("nvim-0.10") ~= 1 then
          pending("a float with hide needs Neovim 0.10")
          return
        end
        open_in_last_tab(layout)
        child.call([[
          local parked = vim.api.nvim_open_win(_G.terminal_buf, false, {
            relative = "editor", row = 1, col = 1, width = 20, height = 5,
          })
          vim.api.nvim_win_set_config(parked, { hide = true })
        ]])

        child.close_diff("first diff")
        child.state()

        assert.is_true(terminal_window_is_open())
      end)
    end)
  end
end)
