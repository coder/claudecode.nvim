if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("a diff tab that stays open: windows the user switched to their own file", function()
    pending("needs a real Neovim")
  end)
  return
end

local helper = require("tests.helpers.new_tab_diff_child")

describe("a diff tab that stays open: windows the user switched to their own file", function()
  local child = helper.new()

  after_each(child.stop)

  local layouts = { "vertical", "unified" }
  local windows = { "proposal", "terminal" }

  for _, layout in ipairs(layouts) do
    for _, window in ipairs(windows) do
      it("keeps the user's file in the former " .. window .. " window with layout = " .. layout, function()
        child.start({ layout = layout, show_terminal_again = true })
        child.open_diff("a.txt", "first diff")
        assert.equal(1, child.close_first_tab().tabs)
        if window == "terminal" then
          child.focus_terminal_in_tab()
          child.leave_terminal_mode()
        end
        local before = child.call(
          [[
          local window = ...
          local diff_data = assert(require("claudecode.diff")._get_active_diffs()["first diff"])
          _G.user_win = assert(window == "proposal" and diff_data.new_window or diff_data.terminal_win_in_new_tab)
          vim.api.nvim_set_current_win(_G.user_win)
          vim.cmd("edit " .. vim.fn.fnameescape(_G.dir .. "/b.txt"))
          _G.user_buf = vim.api.nvim_get_current_buf()
          vim.api.nvim_buf_set_lines(_G.user_buf, 0, -1, false, { "user changed one", "user kept two" })
          return vim.api.nvim_buf_get_lines(_G.user_buf, 0, -1, false)
        ]],
          window
        )

        child.close_diff("first diff")
        child.state()
        local after = child.call([[
          local win_valid = vim.api.nvim_win_is_valid(_G.user_win)
          return {
            cursor_stays = vim.api.nvim_get_current_win() == _G.user_win,
            win_valid = win_valid,
            shown_buf = win_valid and vim.api.nvim_win_get_buf(_G.user_win) or -1,
            user_buf = _G.user_buf,
            lines = vim.api.nvim_buf_get_lines(_G.user_buf, 0, -1, false),
            modified = vim.bo[_G.user_buf].modified,
          }
        ]])

        assert.is_true(after.win_valid, "the window of the user's file must stay open")
        assert.is_true(after.cursor_stays, "the cursor must stay in the window of the user's file")
        assert.equal(after.user_buf, after.shown_buf, "the window must keep showing the user's file")
        assert.same(before, after.lines)
        assert.is_true(after.modified)
        assert.is_true(child.leftovers().job_running)
      end)
    end

    it(
      "drops the terminal's BufEnter handler although the user switched its window, with layout = " .. layout,
      function()
        child.start({ layout = layout, show_terminal_again = true })
        child.open_diff("a.txt", "first diff")
        assert.equal(1, child.close_first_tab().tabs)
        child.focus_terminal_in_tab()
        child.leave_terminal_mode()
        assert.equal(1, child.leftovers().handlers)
        child.call([[
        local diff_data = assert(require("claudecode.diff")._get_active_diffs()["first diff"])
        vim.api.nvim_set_current_win(diff_data.terminal_win_in_new_tab)
        vim.cmd("edit " .. vim.fn.fnameescape(_G.dir .. "/b.txt"))
      ]])

        child.close_diff("first diff")
        local state = child.state()

        assert.equal("n", state.mode)
        assert.equal(0, child.leftovers().handlers)
      end
    )
  end
end)
