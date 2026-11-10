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
        tabs = vim.fn.tabpagenr("$"),
      }
    ]],
      {}
    )
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

        call([[
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_buf(win) == _G.terminal_buf then
              vim.api.nvim_set_current_win(win)
            end
          end
        ]])
        local state = child_state()

        assert.equal("terminal", state.buftype)
        assert.equal("t", state.mode)
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
    end)
  end
end)
