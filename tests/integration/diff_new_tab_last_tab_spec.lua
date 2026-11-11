if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("a diff in a new tab that stays open when Claude closes it", function()
    pending("needs a real Neovim")
  end)
  return
end

local helper = require("tests.helpers.new_tab_diff_child")

describe("a diff in a new tab that stays open when Claude closes it", function()
  local child = helper.new()

  after_each(child.stop)

  local layouts = { "vertical", "unified" }

  for _, layout in ipairs(layouts) do
    describe(
      "with layout = " .. layout .. ", when the user closed the first tab, so the diff tab is the last tab",
      function()
        local function expect_ordinary_tab(state)
          local leftovers = child.leftovers()

          assert.equal(1, state.tabs)
          assert.equal("n", state.mode)
          assert.not_equal("terminal", state.buftype)
          assert.is_false(helper.shows_proposal(state), state.name)
          assert.equal(0, leftovers.in_diff_mode)
          assert.equal(2, leftovers.windows)
          assert.equal(0, leftovers.handlers)
          assert.is_true(leftovers.job_running)
        end

        it("leaves Normal mode in a buffer that is not the diff, without the diff's terminal handler", function()
          child.start({ layout = layout, show_terminal_again = true })
          child.open_diff("a.txt", "first diff")
          assert.equal(1, child.close_first_tab().tabs)

          child.close_diff("first diff")

          expect_ordinary_tab(child.state())
        end)

        it("does the same when the user left the diff tab's terminal in terminal-normal mode", function()
          child.start({ layout = layout, show_terminal_again = true })
          child.open_diff("a.txt", "first diff")
          child.focus_terminal_in_tab()
          child.leave_terminal_mode()
          assert.equal("terminal", child.close_first_tab().buftype)

          child.close_diff("first diff")

          expect_ordinary_tab(child.state())
        end)

        it("keeps a cursor the user moved to a window of their own", function()
          child.start({ layout = layout, show_terminal_again = true })
          child.open_diff("a.txt", "first diff")
          child.close_first_tab()
          child.call([[
          vim.cmd("new")
          _G.user_win = vim.api.nvim_get_current_win()
        ]])

          child.close_diff("first diff")
          local state = child.state()

          assert.is_true(child.call([[return vim.api.nvim_get_current_win() == _G.user_win]]))
          assert.equal("n", state.mode)
        end)

        it(
          "drops the terminal's handler when the user closed every other window, so the terminal cannot close",
          function()
            child.start({ layout = layout, show_terminal_again = true })
            child.open_diff("a.txt", "first diff")
            child.focus_terminal_in_tab()
            child.leave_terminal_mode()
            child.close_first_tab()
            child.call([[
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
              if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) ~= _G.terminal_buf then
                vim.api.nvim_win_close(win, true)
              end
            end
          ]])
            assert.equal(1, child.leftovers().windows)
            assert.equal(1, child.leftovers().handlers)

            child.close_diff("first diff")
            child.state()

            assert.equal(0, child.leftovers().handlers)
            assert.is_true(child.leftovers().job_running)
          end
        )
      end
    )
  end

  describe("with layout = vertical, in the diff tab's windows that show the file", function()
    it("turns diff mode off in a window the user split from the file window", function()
      child.start({ layout = "vertical", show_terminal_again = true })
      child.open_diff("a.txt", "first diff")
      child.close_first_tab()
      child.call([[
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find("a.txt", 1, true) then
            vim.api.nvim_set_current_win(win)
            vim.cmd("split")
          end
        end
      ]])
      assert.equal(3, child.leftovers().in_diff_mode)

      child.close_diff("first diff")
      local state = child.state()

      assert.equal("n", state.mode)
      assert.equal(0, child.leftovers().in_diff_mode)
    end)

    it("turns diff mode off in a window the user split from the file window when 'diffopt' lacks closeoff", function()
      child.start({ layout = "vertical", show_terminal_again = true })
      child.call([[vim.o.diffopt = "internal,filler"]])
      child.open_diff("a.txt", "first diff")
      child.close_first_tab()
      child.call([[
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find("a.txt", 1, true) then
            vim.api.nvim_set_current_win(win)
            vim.cmd("split")
            break
          end
        end
      ]])

      child.close_diff("first diff")
      child.state()

      assert.equal(0, child.leftovers().in_diff_mode)
    end)

    it("turns diff mode off when 'diffopt' lacks closeoff", function()
      child.start({ layout = "vertical", show_terminal_again = true })
      child.call([[vim.o.diffopt = "internal,filler"]])
      child.open_diff("a.txt", "first diff")
      child.close_first_tab()

      child.close_diff("first diff")
      local state = child.state()

      assert.equal("n", state.mode)
      assert.equal(0, child.leftovers().in_diff_mode)
    end)

    it("turns diff mode off in the proposal window when the user closed the file window", function()
      child.start({ layout = "vertical", show_terminal_again = true })
      child.call([[vim.o.diffopt = "internal,filler"]])
      child.open_diff("a.txt", "first diff")
      child.close_first_tab()
      child.call([[
        local diff_data = assert(require("claudecode.diff")._get_active_diffs()["first diff"])
        vim.api.nvim_win_close(diff_data.target_window, true)
      ]])
      assert.equal(1, child.leftovers().in_diff_mode, "the proposal window must still be in diff mode before the close")

      child.close_diff("first diff")
      local state = child.state()

      assert.equal("n", state.mode)
      assert.equal(0, child.leftovers().in_diff_mode)
    end)
  end)
end)
