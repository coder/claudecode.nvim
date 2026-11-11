-- A pending `startinsert` starts only when Neovim's main loop is back in control, so the mode is read from a child
-- Neovim over RPC after the call that opened the diff has returned.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff in a new tab: mode", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openDiff in a new tab: mode", function()
  local chan

  local function call(code, ...)
    return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
  end

  local function start_child(opts)
    chan = vim.fn.jobstart({
      vim.v.progpath,
      "--embed",
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "--cmd",
      "set rtp^=" .. vim.fn.getcwd(),
    }, { rpc = true })
    assert.is_true(chan > 0, "could not start a child Neovim")
    call(
      [[
      local opts = ...
      vim.o.swapfile = false
      _G.dir = vim.fn.tempname()
      vim.fn.mkdir(_G.dir, "p")
      vim.fn.writefile({ "alpha", "beta" }, _G.dir .. "/a.txt")
      vim.fn.writefile({ "one", "two" }, _G.dir .. "/b.txt")
      vim.cmd("edit " .. _G.dir .. "/a.txt")

      vim.cmd("botright vsplit")
      _G.terminal_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), _G.terminal_buf)
      _G.job = vim.fn.termopen({ "sleep", "60" })
      vim.cmd("wincmd p")
      if opts.hide_original_terminal then
        for _, win in ipairs(vim.fn.win_findbuf(_G.terminal_buf)) do
          vim.api.nvim_win_close(win, true)
        end
      end
      package.loaded["claudecode.terminal"] = {
        get_active_terminal_bufnr = function()
          return _G.terminal_buf
        end,
        ensure_visible = function() end,
      }
      if opts.snacks_auto_insert then
        vim.api.nvim_create_autocmd("BufEnter", {
          buffer = _G.terminal_buf,
          callback = function()
            vim.cmd("startinsert")
          end,
        })
      end

      local config = vim.deepcopy(require("claudecode.config").defaults)
      config.diff_opts.layout = opts.layout
      config.diff_opts.open_in_new_tab = true
      config.diff_opts.keep_terminal_focus = opts.keep_terminal_focus == true
      config.terminal = config.terminal or {}
      config.terminal.auto_insert = opts.auto_insert ~= false
      require("claudecode.diff").setup(config)
      require("claudecode.tools.init").register_all()
      _G.claude_deferred_responses = {}
    ]],
      opts
    )
  end

  local function stop_child()
    if chan then
      pcall(vim.rpcrequest, chan, "nvim_exec_lua", "pcall(vim.fn.jobstop, _G.job)", {})
      vim.fn.jobstop(chan)
      vim.fn.jobwait({ chan }, 3000)
      chan = nil
    end
  end

  local function open_diff(file, tab_name)
    call(
      [[
      local file, tab_name = ...
      local path = _G.dir .. "/" .. file
      local response = require("claudecode.tools.init").handle_invoke({ id = "mode_spec_client" }, {
        name = "openDiff",
        arguments = { old_file_path = path, new_file_path = path, new_file_contents = "new\ntext\n", tab_name = tab_name },
      })
      assert(response._deferred, vim.inspect(response.error))
    ]],
      file,
      tab_name
    )
  end

  -- Gives the child's main loop time to start a pending insert.
  local function child_state()
    vim.wait(150)
    return vim.rpcrequest(
      chan,
      "nvim_exec_lua",
      [[
      local buf = vim.api.nvim_get_current_buf()
      return {
        mode = vim.api.nvim_get_mode().mode,
        name = vim.api.nvim_buf_get_name(buf),
        buftype = vim.bo[buf].buftype,
        tab = vim.fn.tabpagenr(),
        tabs = vim.fn.tabpagenr("$"),
      }
    ]],
      {}
    )
  end

  local function focus_terminal_in_tab()
    call([[
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == _G.terminal_buf then
          vim.api.nvim_set_current_win(win)
        end
      end
    ]])
  end

  -- The original tab keeps its own window on the terminal buffer. Entering it fires the diff's BufEnter handler.
  local function enter_terminal_from_original_tab()
    call([[
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
    call(
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
      return vim.rpcrequest(chan, "nvim_get_mode").mode == "t"
    end, 50)
  end

  local function terminal_window_count()
    return call("return #vim.fn.win_findbuf(_G.terminal_buf)")
  end

  -- Opens the terminal buffer in a new split of the original tab. That entry fires the handler too.
  local function split_terminal_in_original_tab()
    call([[
      vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
      vim.cmd("sbuffer " .. _G.terminal_buf)
    ]])
  end

  -- Leaves terminal mode as a user would, then moves to the original tab's editor window.
  local function leave_terminal_for_editor_window()
    vim.rpcrequest(chan, "nvim_input", "<C-\\><C-n>")
    vim.wait(150)
    call([[
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_list_tabpages()[1])) do
        if vim.api.nvim_win_get_buf(win) ~= _G.terminal_buf then
          vim.api.nvim_set_current_win(win)
          return
        end
      end
      error("the original tab shows no editor window")
    ]])
  end

  local function shows_proposal(state)
    return state.name:find("(proposed)", 1, true) ~= nil or state.name:find("(unified diff)", 1, true) ~= nil
  end

  after_each(stop_child)

  local layouts = { "vertical", "unified" }

  for _, layout in ipairs(layouts) do
    describe("with layout = " .. layout, function()
      it("keeps a second diff in a new tab in Normal mode", function()
        start_child({ layout = layout })

        open_diff("a.txt", "first diff")
        local first = child_state()
        open_diff("b.txt", "second diff")
        local second = child_state()

        assert.equal(2, first.tabs)
        assert.is_true(shows_proposal(first), first.name)
        assert.equal("n", first.mode)
        assert.equal(3, second.tabs)
        assert.is_true(shows_proposal(second), second.name)
        assert.equal("n", second.mode)
      end)

      it("keeps a diff in Normal mode when the terminal buffer auto-inserts on BufEnter, as with Snacks", function()
        start_child({ layout = layout, snacks_auto_insert = true })

        open_diff("a.txt", "first diff")
        local first = child_state()
        open_diff("b.txt", "second diff")
        local second = child_state()

        assert.is_true(shows_proposal(first), first.name)
        assert.equal("n", first.mode)
        assert.is_true(shows_proposal(second), second.name)
        assert.equal("n", second.mode)
      end)

      it("still enters terminal mode when the user focuses the terminal in the new tab", function()
        start_child({ layout = layout, snacks_auto_insert = true })
        open_diff("a.txt", "first diff")
        open_diff("b.txt", "second diff")
        assert.equal("n", child_state().mode)

        focus_terminal_in_tab()
        local state = child_state()

        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)

      it("enters terminal mode on focusing the terminal in the new tab through the diff's own handler", function()
        start_child({ layout = layout })
        open_diff("a.txt", "first diff")
        assert.equal("n", child_state().mode)

        focus_terminal_in_tab()
        local state = child_state()

        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)

      it("stays in terminal-normal mode on focusing that terminal with terminal.auto_insert = false", function()
        start_child({ layout = layout, auto_insert = false })
        open_diff("a.txt", "first diff")

        focus_terminal_in_tab()
        local state = child_state()

        assert.equal("terminal", state.buftype)
        assert.equal("nt", state.mode)
      end)

      it("leaves the cursor in the terminal, in terminal mode, with keep_terminal_focus", function()
        start_child({ layout = layout, keep_terminal_focus = true })

        open_diff("a.txt", "first diff")
        vim.wait(1000, function()
          return vim.rpcrequest(chan, "nvim_get_mode").mode == "t"
        end, 50)
        local state = child_state()

        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)

      it("enters terminal mode from the original tab while the diff tab's terminal window lives", function()
        start_child({ layout = layout })
        open_diff("a.txt", "diff")
        assert.equal("n", child_state().mode)

        enter_terminal_from_original_tab()
        wait_for_terminal_mode()
        local state = child_state()

        assert.equal(1, state.tab)
        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)

      it("enters terminal mode from the original tab after that window shows another buffer", function()
        start_child({ layout = layout })
        open_diff("a.txt", "diff")
        change_diff_tab_terminal_window("swap")

        enter_terminal_from_original_tab()
        wait_for_terminal_mode()
        local state = child_state()

        assert.equal(1, state.tab)
        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)

      it("stays in terminal-normal mode from the original tab after that window closes", function()
        start_child({ layout = layout })
        open_diff("a.txt", "diff")
        change_diff_tab_terminal_window("close")

        enter_terminal_from_original_tab()
        local state = child_state()

        assert.equal(1, state.tab)
        assert.equal("terminal", state.buftype)
        assert.equal("nt", state.mode)
      end)

      it("enters terminal mode when the swapped window was the only one that showed the terminal", function()
        start_child({ layout = layout, hide_original_terminal = true })
        open_diff("a.txt", "diff")
        assert.equal(1, terminal_window_count(), "only the diff tab's window shows the terminal")
        change_diff_tab_terminal_window("swap")
        assert.equal(0, terminal_window_count(), "no window shows the terminal")

        split_terminal_in_original_tab()
        wait_for_terminal_mode()
        local state = child_state()

        assert.equal(1, state.tab)
        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)

      it("enters terminal mode on every entry from the original tab, not only the first", function()
        start_child({ layout = layout })
        open_diff("a.txt", "diff")

        enter_terminal_from_original_tab()
        wait_for_terminal_mode()
        assert.equal("t", child_state().mode)
        leave_terminal_for_editor_window()
        local between = child_state()
        assert.equal("", between.buftype)
        assert.equal("n", between.mode)

        enter_terminal_from_original_tab()
        wait_for_terminal_mode()
        local state = child_state()

        assert.equal(1, state.tab)
        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
      end)
    end)
  end
end)
