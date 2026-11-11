-- A child Neovim that runs the plugin's diff in a new tab next to a real terminal job, driven over RPC. A pending
-- `startinsert` starts only when the child's main loop is back in control, so a test reads the child's mode after the
-- call that opened or closed the diff has returned.
local M = {}

---@param state table
---@return boolean
function M.shows_proposal(state)
  return state.name:find("(proposed)", 1, true) ~= nil or state.name:find("(unified diff)", 1, true) ~= nil
end

---@return table child The child's handle: start, stop, call, state and the user's and Claude's actions
function M.new()
  local child = {}
  local chan

  function child.call(code, ...)
    return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
  end

  ---@param opts table layout, snacks_auto_insert, keep_terminal_focus, auto_insert, show_terminal_again,
  ---hide_original_terminal
  function child.start(opts)
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
    child.call(
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
        ensure_visible = function()
          if opts.show_terminal_again then
            local current = vim.api.nvim_get_current_win()
            vim.cmd("botright vsplit")
            vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), _G.terminal_buf)
            vim.api.nvim_set_current_win(current)
          end
        end,
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

  function child.stop()
    if chan then
      pcall(vim.rpcrequest, chan, "nvim_exec_lua", "pcall(vim.fn.jobstop, _G.job)", {})
      vim.fn.jobstop(chan)
      vim.fn.jobwait({ chan }, 3000)
      chan = nil
    end
  end

  function child.channel()
    return chan
  end

  function child.mode()
    return vim.rpcrequest(chan, "nvim_get_mode").mode
  end

  -- Gives the child's main loop time to start a pending insert.
  function child.state()
    vim.wait(150)
    return child.call([[
      local buf = vim.api.nvim_get_current_buf()
      return {
        mode = vim.api.nvim_get_mode().mode,
        name = vim.api.nvim_buf_get_name(buf),
        buftype = vim.bo[buf].buftype,
        tab = vim.fn.tabpagenr(),
        tabs = vim.fn.tabpagenr("$"),
      }
    ]])
  end

  function child.open_diff(file, tab_name)
    child.call(
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

  function child.close_diff(tab_name)
    child.call(
      [[
      local tab_name = ...
      local response = require("claudecode.tools.init").handle_invoke({ id = "mode_spec_client" }, {
        name = "close_tab",
        arguments = { tab_name = tab_name },
      })
      assert(response.result, vim.inspect(response.error))
    ]],
      tab_name
    )
  end

  function child.focus_terminal_in_tab()
    child.call([[
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == _G.terminal_buf then
          vim.api.nvim_set_current_win(win)
        end
      end
    ]])
  end

  function child.leave_terminal_mode()
    vim.rpcrequest(chan, "nvim_input", "<C-\\><C-N>")
    return child.state()
  end

  function child.go_to_first_tab()
    child.call([[vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])]])
    return child.state()
  end

  function child.close_first_tab()
    child.call([[
      vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
      vim.cmd("tabclose")
    ]])
    return child.state()
  end

  ---What of the diff is left in the current tab: the diff's terminal handler, windows, windows in diff mode.
  function child.leftovers()
    return child.call([[
      local handlers = 0
      for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "BufEnter", group = "ClaudeCodeMCPDiff" })) do
        if autocmd.buflocal and autocmd.buffer == _G.terminal_buf then
          handlers = handlers + 1
        end
      end
      local wins = vim.api.nvim_tabpage_list_wins(0)
      local in_diff_mode = 0
      for _, win in ipairs(wins) do
        if vim.wo[win].diff or vim.wo[win].scrollbind or vim.wo[win].foldmethod == "diff" then
          in_diff_mode = in_diff_mode + 1
        end
      end
      return {
        handlers = handlers,
        windows = #wins,
        in_diff_mode = in_diff_mode,
        job_running = vim.fn.jobwait({ _G.job }, 0)[1] == -1,
      }
    ]])
  end

  return child
end

return M
