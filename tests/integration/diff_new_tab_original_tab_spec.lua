if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("a diff in a new tab: the terminal handler from the original tab", function()
    pending("needs a real Neovim")
  end)
  return
end

local helper = require("tests.helpers.new_tab_diff_child")

describe("a diff in a new tab: the terminal handler from the original tab", function()
  local child = helper.new()

  after_each(child.stop)

  -- The original tab keeps its own window on the terminal buffer. Entering it fires the diff's BufEnter handler.
  local function enter_terminal_from_original_tab()
    child.call([[
      local original_tab = vim.api.nvim_list_tabpages()[1]
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(original_tab)) do
        if vim.api.nvim_win_get_buf(win) == _G.terminal_buf then
          vim.api.nvim_set_current_win(win)
          return
        end
      end
      error("the original tab shows no terminal window")
    ]])
  end

  -- Changes the diff tab's terminal window without entering it: "swap" shows another file in it, "close" closes it.
  local function change_diff_tab_terminal_window(action)
    child.call(
      [[
      local action = ...
      local diff_tab = vim.api.nvim_list_tabpages()[2]
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(diff_tab)) do
        if vim.api.nvim_win_get_buf(win) == _G.terminal_buf then
          if action == "swap" then
            local other = vim.fn.bufadd(_G.dir .. "/b.txt")
            vim.fn.bufload(other)
            vim.api.nvim_win_set_buf(win, other)
          else
            vim.api.nvim_win_close(win, true)
          end
          return
        end
      end
      error("the diff tab shows no terminal window")
    ]],
      action
    )
  end

  local function wait_for_terminal_mode()
    vim.wait(1000, function()
      return child.mode() == "t"
    end, 50)
  end

  local function terminal_window_count()
    return child.call("return #vim.fn.win_findbuf(_G.terminal_buf)")
  end

  -- Opens the terminal buffer in a new split of the original tab. That entry fires the handler too.
  local function split_terminal_in_original_tab()
    child.call([[
      vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
      vim.cmd("sbuffer " .. _G.terminal_buf)
    ]])
  end

  -- Leaves terminal mode as a user would, then moves to the original tab's editor window.
  local function leave_terminal_for_editor_window()
    vim.rpcrequest(child.channel(), "nvim_input", "<C-\\><C-n>")
    vim.wait(150)
    child.call([[
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_list_tabpages()[1])) do
        if vim.api.nvim_win_get_buf(win) ~= _G.terminal_buf then
          vim.api.nvim_set_current_win(win)
          return
        end
      end
      error("the original tab shows no editor window")
    ]])
  end

  local layouts = { "vertical", "unified" }

  for _, layout in ipairs(layouts) do
    describe("with layout = " .. layout, function()
      it("enters terminal mode from the original tab while the diff tab's terminal window lives", function()
        child.start({ layout = layout })
        child.open_diff("a.txt", "diff")
        assert.equal("n", child.state().mode)

        enter_terminal_from_original_tab()
        wait_for_terminal_mode()
        local state = child.state()

        assert.equal(1, state.tab)
        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)

      it("enters terminal mode from the original tab after that window shows another buffer", function()
        child.start({ layout = layout })
        child.open_diff("a.txt", "diff")
        change_diff_tab_terminal_window("swap")

        enter_terminal_from_original_tab()
        wait_for_terminal_mode()
        local state = child.state()

        assert.equal(1, state.tab)
        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)

      it("stays in terminal-normal mode from the original tab after that window closes", function()
        child.start({ layout = layout })
        child.open_diff("a.txt", "diff")
        change_diff_tab_terminal_window("close")

        enter_terminal_from_original_tab()
        local state = child.state()

        assert.equal(1, state.tab)
        assert.equal("terminal", state.buftype)
        assert.equal("nt", state.mode)
      end)

      it("enters terminal mode when the swapped window was the only one that showed the terminal", function()
        child.start({ layout = layout, hide_original_terminal = true })
        child.open_diff("a.txt", "diff")
        assert.equal(1, terminal_window_count(), "only the diff tab's window shows the terminal")
        change_diff_tab_terminal_window("swap")
        assert.equal(0, terminal_window_count(), "no window shows the terminal")

        split_terminal_in_original_tab()
        wait_for_terminal_mode()
        local state = child.state()

        assert.equal(1, state.tab)
        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)

      it("enters terminal mode on every entry from the original tab, not only the first", function()
        child.start({ layout = layout })
        child.open_diff("a.txt", "diff")

        enter_terminal_from_original_tab()
        wait_for_terminal_mode()
        assert.equal("t", child.state().mode)
        leave_terminal_for_editor_window()
        local between = child.state()
        assert.equal("", between.buftype)
        assert.equal("n", between.mode)

        enter_terminal_from_original_tab()
        wait_for_terminal_mode()
        local state = child.state()

        assert.equal(1, state.tab)
        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)
    end)
  end
end)
