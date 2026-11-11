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
  end)

  describe("with layout = vertical, when :tabclose stops at a modified buffer of the user's", function()
    it("closes the diff's windows, keeps the user's, and leaves the user in their tab in Normal mode", function()
      child.start({ layout = "vertical", show_terminal_again = true })
      child.call([[vim.o.hidden = false]])
      child.open_diff("a.txt", "first diff")
      child.call([[
        vim.cmd("split " .. _G.dir .. "/b.txt")
        vim.api.nvim_buf_set_lines(0, 0, 1, false, { "one!" })
      ]])
      child.go_to_first_tab()

      child.close_diff("first diff")
      local state = child.state()

      assert.equal(2, state.tabs)
      assert.equal("n", state.mode)
      assert.is_true(state.name:find("a.txt", 1, true) ~= nil, state.name)
      assert.equal(0, child.leftovers().handlers)
      local diff_tab = child.call([[
        local names = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_list_tabpages()[2])) do
          local buf = vim.api.nvim_win_get_buf(win)
          local name = vim.bo[buf].buftype == "terminal" and "TERMINAL" or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
          table.insert(names, name .. (vim.bo[buf].modified and "+" or ""))
        end
        table.sort(names)
        return names
      ]])
      assert.same({ "a.txt", "b.txt+" }, diff_tab)
    end)
  end)
end)
