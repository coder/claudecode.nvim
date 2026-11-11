if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff in a new tab: the terminal split", function()
    pending("needs a real Neovim")
  end)
  return
end

-- Neovim loads a buffer into the window that a BufLeave autocmd entered while `nvim_win_set_buf` runs, even when the call
-- names another window. The terminal split of a new diff tab must still show the terminal, and the other window of the
-- tab must keep its own buffer.
describe("openDiff in a new tab: the terminal split", function()
  local chan

  local function call(code, ...)
    return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
  end

  local function start_child()
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
    call([[
      vim.o.swapfile = false
      _G.dir = vim.fn.tempname()
      vim.fn.mkdir(_G.dir, "p")
      vim.fn.writefile({ "alpha", "beta" }, _G.dir .. "/a.txt")
      vim.cmd("edit " .. vim.fn.fnameescape(_G.dir .. "/a.txt"))

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

      local config = vim.deepcopy(require("claudecode.config").defaults)
      config.diff_opts.layout = "vertical"
      config.diff_opts.open_in_new_tab = true
      config.terminal = config.terminal or {}
      config.terminal.split_side = "right"
      require("claudecode.diff").setup(config)
      require("claudecode.tools.init").register_all()
      _G.claude_deferred_responses = {}
    ]])
  end

  ---A BufLeave autocmd of the user's that enters the other window of the new tab, once the tab has its two windows.
  local function arm_bufleave_autocmd()
    call([[
      _G.runs = 0
      vim.api.nvim_create_autocmd("BufLeave", {
        callback = function()
          if vim.fn.tabpagenr() == 2 and #vim.api.nvim_tabpage_list_wins(0) == 2 then
            _G.runs = _G.runs + 1
            vim.cmd("wincmd p")
            return true
          end
        end,
      })
    ]])
  end

  local function open_diff()
    call([[
      local path = _G.dir .. "/a.txt"
      local response = require("claudecode.tools.init").handle_invoke({ id = "terminal_swap_spec_client" }, {
        name = "openDiff",
        arguments = { old_file_path = path, new_file_path = path, new_file_contents = "new\ntext\n", tab_name = "swap" },
      })
      assert(response._deferred, vim.inspect(response.error))
    ]])
  end

  ---The buffers of the windows of the new tab, from left to right: "TERM" for the terminal, else the file name.
  local function new_tab_buffers()
    return call([[
      local names = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
        local buf = vim.api.nvim_win_get_buf(win)
        table.insert(names, buf == _G.terminal_buf and "TERM" or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"))
      end
      return { names = names, tab = vim.fn.tabpagenr(), runs = _G.runs }
    ]])
  end

  after_each(function()
    if chan then
      pcall(vim.rpcrequest, chan, "nvim_exec_lua", "pcall(vim.fn.jobstop, _G.job)", {})
      vim.fn.jobstop(chan)
      vim.fn.jobwait({ chan }, 3000)
      chan = nil
    end
  end)

  it("shows the terminal in the split it made, also when a BufLeave autocmd enters the other window", function()
    start_child()
    arm_bufleave_autocmd()

    open_diff()

    local state = new_tab_buffers()
    assert.equal(2, state.tab)
    assert.equal(1, state.runs, "the autocmd must have run during the swap, or the test proves nothing")
    local terminal_windows = 0
    for _, name in ipairs(state.names) do
      if name == "TERM" then
        terminal_windows = terminal_windows + 1
      end
    end
    assert.equal(1, terminal_windows, "the new tab must show the terminal once: " .. vim.inspect(state.names))
    assert.equal(
      "TERM",
      state.names[#state.names],
      "the terminal split must be on the right: " .. vim.inspect(state.names)
    )
  end)
end)
