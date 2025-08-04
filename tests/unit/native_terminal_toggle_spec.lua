describe("claudecode.terminal.native toggle behavior", function()
  local native_provider
  local mock_vim
  local logger_spy

  before_each(function()
    -- Set up the package path for tests
    package.path = "./lua/?.lua;" .. package.path

    -- Clean up any loaded modules
    package.loaded["claudecode.terminal.native"] = nil
    package.loaded["claudecode.logger"] = nil

    -- Mock state for more realistic testing
    local mock_state = {
      buffers = {},
      windows = {},
      current_win = 1,
      next_bufnr = 1,
      next_winid = 1000,
      next_jobid = 10000,
      buffer_options = {},
    }

    -- Mock vim API with stateful behavior
    mock_vim = {
      api = {
        nvim_buf_is_valid = function(bufnr)
          return mock_state.buffers[bufnr] ~= nil
        end,
        nvim_win_is_valid = function(winid)
          return mock_state.windows[winid] ~= nil
        end,
        nvim_list_wins = function()
          local wins = {}
          for winid, _ in pairs(mock_state.windows) do
            table.insert(wins, winid)
          end
          return wins
        end,
        nvim_list_bufs = function()
          local bufs = {}
          for bufnr, _ in pairs(mock_state.buffers) do
            table.insert(bufs, bufnr)
          end
          return bufs
        end,
        nvim_buf_get_name = function(bufnr)
          local buf = mock_state.buffers[bufnr]
          return buf and buf.name or ""
        end,
        nvim_buf_get_option = function(bufnr, option)
          local buf = mock_state.buffers[bufnr]
          if buf and buf.options and buf.options[option] then
            return buf.options[option]
          end
          return ""
        end,
        nvim_buf_set_option = function(bufnr, option, value)
          local buf = mock_state.buffers[bufnr]
          if buf then
            buf.options = buf.options or {}
            buf.options[option] = value
            -- Track calls for verification
            mock_state.buffer_options[bufnr] = mock_state.buffer_options[bufnr] or {}
            mock_state.buffer_options[bufnr][option] = value
          end
        end,
        nvim_win_get_buf = function(winid)
          local win = mock_state.windows[winid]
          return win and win.bufnr or 0
        end,
        nvim_win_close = function(winid, force)
          -- Remove window from state (simulates window closing)
          if winid and mock_state.windows[winid] then
            mock_state.windows[winid] = nil
          end
        end,
        nvim_get_current_win = function()
          return mock_state.current_win
        end,
        nvim_get_current_buf = function()
          local current_win = mock_state.current_win
          local win = mock_state.windows[current_win]
          return win and win.bufnr or 0
        end,
        nvim_set_current_win = function(winid)
          if mock_state.windows[winid] then
            mock_state.current_win = winid
          end
        end,
        nvim_win_set_buf = function(winid, bufnr)
          local win = mock_state.windows[winid]
          if win and mock_state.buffers[bufnr] then
            win.bufnr = bufnr
          end
        end,
        nvim_win_set_height = function(winid, height)
          -- Mock window resizing
        end,
        nvim_win_set_width = function(winid, width)
          -- Mock window resizing
        end,
        nvim_win_call = function(winid, fn)
          -- Mock window-specific function execution
          return fn()
        end,
      },
      cmd = function(command)
        -- Handle vsplit and other commands
        if command:match("^topleft %d+vsplit") or command:match("^botright %d+vsplit") then
          -- Create new window
          local winid = mock_state.next_winid
          mock_state.next_winid = mock_state.next_winid + 1
          mock_state.windows[winid] = { bufnr = 0 }
          mock_state.current_win = winid
        elseif command == "enew" then
          -- Create new buffer in current window
          local bufnr = mock_state.next_bufnr
          mock_state.next_bufnr = mock_state.next_bufnr + 1
          mock_state.buffers[bufnr] = { name = "", options = {} }
          if mock_state.windows[mock_state.current_win] then
            mock_state.windows[mock_state.current_win].bufnr = bufnr
          end
        end
      end,
      o = {
        columns = 120,
        lines = 40,
      },
      fn = {
        termopen = function(cmd, opts)
          local jobid = mock_state.next_jobid
          mock_state.next_jobid = mock_state.next_jobid + 1

          -- Create terminal buffer
          local bufnr = mock_state.next_bufnr
          mock_state.next_bufnr = mock_state.next_bufnr + 1
          mock_state.buffers[bufnr] = {
            name = "term://claude",
            options = { buftype = "terminal", bufhidden = "wipe" },
            jobid = jobid,
            on_exit = opts.on_exit,
          }

          -- Set buffer in current window
          if mock_state.windows[mock_state.current_win] then
            mock_state.windows[mock_state.current_win].bufnr = bufnr
          end

          return jobid
        end,
      },
      schedule = function(callback)
        callback() -- Execute immediately in tests
      end,
      bo = setmetatable({}, {
        __index = function(_, bufnr)
          return setmetatable({}, {
            __newindex = function(_, option, value)
              -- Mock buffer option setting
              local buf = mock_state.buffers[bufnr]
              if buf then
                buf.options = buf.options or {}
                buf.options[option] = value
              end
            end,
            __index = function(_, option)
              local buf = mock_state.buffers[bufnr]
              return buf and buf.options and buf.options[option] or ""
            end,
          })
        end,
      }),
    }
    _G.vim = mock_vim

    -- Mock logger
    logger_spy = {
      debug = function(module, message, ...)
        -- Track debug calls for verification
      end,
      error = function(module, message, ...)
        -- Track error calls
      end,
    }
    package.loaded["claudecode.logger"] = logger_spy

    -- Load the native provider
    native_provider = require("claudecode.terminal.native")
    native_provider.setup({})

    -- Helper function to get mock state for verification
    _G.get_mock_state = function()
      return mock_state
    end
  end)

  after_each(function()
    _G.vim = nil
    package.loaded["claudecode.terminal.native"] = nil
    package.loaded["claudecode.logger"] = nil
  end)

  describe("toggle with no existing terminal", function()
    it("should create a new terminal when none exists", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Mock termopen to succeed
      mock_vim.fn.termopen = function(cmd, opts)
        assert.are.equal(cmd_string, cmd[1])
        assert.are.same(env_table, opts.env)
        return 12345 -- Valid job ID
      end

      native_provider.toggle(cmd_string, env_table, config)

      -- Should have created terminal and have active buffer
      assert.is_not_nil(native_provider.get_active_bufnr())
    end)
  end)

  describe("toggle with existing hidden terminal", function()
    it("should show hidden terminal instead of creating new one", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- First create a terminal
      mock_vim.fn.termopen = function(cmd, opts)
        return 12345 -- Valid job ID
      end
      native_provider.open(cmd_string, env_table, config)

      local initial_bufnr = native_provider.get_active_bufnr()
      assert.is_not_nil(initial_bufnr)

      -- Simulate hiding the terminal (buffer exists but no window shows it)
      mock_vim.api.nvim_list_wins = function()
        return { 1, 3 } -- Window 2 (which had our buffer) is gone
      end
      mock_vim.api.nvim_win_get_buf = function(winid)
        return 50 -- Other windows have different buffers
      end

      -- Mock window creation for showing hidden terminal
      local vsplit_called = false
      local original_cmd = mock_vim.cmd
      mock_vim.cmd = function(command)
        if command:match("vsplit") then
          vsplit_called = true
        end
        original_cmd(command)
      end

      mock_vim.api.nvim_get_current_win = function()
        return 4 -- New window created
      end

      -- Toggle should show the hidden terminal
      native_provider.toggle(cmd_string, env_table, config)

      -- Should not have created a new buffer/job, just shown existing one
      assert.are.equal(initial_bufnr, native_provider.get_active_bufnr())
      assert.is_true(vsplit_called)
    end)
  end)

  describe("toggle with visible terminal", function()
    it("should hide terminal when toggling from inside it and set bufhidden=hide", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Create a terminal by opening it
      native_provider.open(cmd_string, env_table, config)
      local initial_bufnr = native_provider.get_active_bufnr()
      assert.is_not_nil(initial_bufnr)

      local mock_state = _G.get_mock_state()

      -- Verify initial state - buffer should exist and have a window
      assert.is_not_nil(mock_state.buffers[initial_bufnr])
      assert.are.equal("hide", mock_state.buffers[initial_bufnr].options.bufhidden)

      -- Find the window that contains our terminal buffer
      local terminal_winid = nil
      for winid, win in pairs(mock_state.windows) do
        if win.bufnr == initial_bufnr then
          terminal_winid = winid
          break
        end
      end
      assert.is_not_nil(terminal_winid)

      -- Mock that we're currently in the terminal window
      mock_state.current_win = terminal_winid

      -- Toggle should hide the terminal
      native_provider.toggle(cmd_string, env_table, config)

      -- Verify the critical behavior:
      -- 1. Buffer should still exist and be valid
      assert.are.equal(initial_bufnr, native_provider.get_active_bufnr())
      assert.is_not_nil(mock_state.buffers[initial_bufnr])

      -- 2. Window should be closed/invalid
      assert.is_nil(mock_state.windows[terminal_winid])
    end)

    it("should focus terminal when focus toggling from outside it", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Create a terminal
      native_provider.open(cmd_string, env_table, config)
      local initial_bufnr = native_provider.get_active_bufnr()
      local mock_state = _G.get_mock_state()

      -- Find the terminal window that was created
      local terminal_winid = nil
      for winid, win in pairs(mock_state.windows) do
        if win.bufnr == initial_bufnr then
          terminal_winid = winid
          break
        end
      end
      assert.is_not_nil(terminal_winid)

      -- Mock that we're NOT in the terminal window (simulate being in a different window)
      mock_state.current_win = 1 -- Some other window

      local set_current_win_called = false
      local focused_winid = nil
      local original_set_current_win = mock_vim.api.nvim_set_current_win
      mock_vim.api.nvim_set_current_win = function(winid)
        set_current_win_called = true
        focused_winid = winid
        return original_set_current_win(winid)
      end

      -- Focus toggle should focus the terminal
      native_provider.focus_toggle(cmd_string, env_table, config)

      -- Should have focused the terminal window
      assert.is_true(set_current_win_called)
      assert.are.equal(terminal_winid, focused_winid)
      assert.are.equal(initial_bufnr, native_provider.get_active_bufnr())
    end)
  end)

  describe("close vs toggle behavior", function()
    it("should preserve process on toggle but kill on close", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Create a terminal
      native_provider.open(cmd_string, env_table, config)
      local initial_bufnr = native_provider.get_active_bufnr()
      assert.is_not_nil(initial_bufnr)

      local mock_state = _G.get_mock_state()

      -- Find the terminal window
      local terminal_winid = nil
      for winid, win in pairs(mock_state.windows) do
        if win.bufnr == initial_bufnr then
          terminal_winid = winid
          break
        end
      end

      -- Mock being in terminal window
      mock_state.current_win = terminal_winid

      -- Toggle should hide but preserve process
      native_provider.toggle(cmd_string, env_table, config)
      assert.are.equal(initial_bufnr, native_provider.get_active_bufnr())

      -- Close should kill the process (cleanup_state called)
      native_provider.close()
      assert.is_nil(native_provider.get_active_bufnr())
    end)
  end)

  describe("simple_toggle behavior", function()
    it("should always hide terminal when visible, regardless of focus", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Create a terminal
      native_provider.open(cmd_string, env_table, config)
      local initial_bufnr = native_provider.get_active_bufnr()
      local mock_state = _G.get_mock_state()

      -- Find the terminal window
      local terminal_winid = nil
      for winid, win in pairs(mock_state.windows) do
        if win.bufnr == initial_bufnr then
          terminal_winid = winid
          break
        end
      end

      -- Test 1: Not in terminal window - simple_toggle should still hide
      mock_state.current_win = 1 -- Different window
      native_provider.simple_toggle(cmd_string, env_table, config)

      -- Should have hidden the terminal (closed window)
      assert.is_nil(mock_state.windows[terminal_winid])
    end)

    it("should always show terminal when not visible", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Start with no terminal
      assert.is_nil(native_provider.get_active_bufnr())

      -- Simple toggle should create new terminal
      native_provider.simple_toggle(cmd_string, env_table, config)

      -- Should have created terminal
      assert.is_not_nil(native_provider.get_active_bufnr())
    end)

    it("should show hidden terminal when toggled", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Create and then hide a terminal
      native_provider.open(cmd_string, env_table, config)
      local initial_bufnr = native_provider.get_active_bufnr()
      native_provider.simple_toggle(cmd_string, env_table, config) -- Hide it

      -- Mock window creation for showing hidden terminal
      local vsplit_called = false
      local original_cmd = mock_vim.cmd
      mock_vim.cmd = function(command)
        if command:match("vsplit") then
          vsplit_called = true
        end
        original_cmd(command)
      end

      -- Simple toggle should show the hidden terminal
      native_provider.simple_toggle(cmd_string, env_table, config)

      -- Should have shown the existing terminal
      assert.are.equal(initial_bufnr, native_provider.get_active_bufnr())
      assert.is_true(vsplit_called)
    end)
  end)

  describe("focus_toggle behavior", function()
    it("should focus terminal when visible but not focused", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Create a terminal
      native_provider.open(cmd_string, env_table, config)
      local initial_bufnr = native_provider.get_active_bufnr()
      local mock_state = _G.get_mock_state()

      -- Find the terminal window
      local terminal_winid = nil
      for winid, win in pairs(mock_state.windows) do
        if win.bufnr == initial_bufnr then
          terminal_winid = winid
          break
        end
      end

      -- Mock that we're NOT in the terminal window
      mock_state.current_win = 1 -- Some other window

      local set_current_win_called = false
      local focused_winid = nil
      local original_set_current_win = mock_vim.api.nvim_set_current_win
      mock_vim.api.nvim_set_current_win = function(winid)
        set_current_win_called = true
        focused_winid = winid
        return original_set_current_win(winid)
      end

      -- Focus toggle should focus the terminal
      native_provider.focus_toggle(cmd_string, env_table, config)

      -- Should have focused the terminal window
      assert.is_true(set_current_win_called)
      assert.are.equal(terminal_winid, focused_winid)
    end)

    it("should hide terminal when focused and toggle called", function()
      local cmd_string = "claude"
      local env_table = { TEST = "value" }
      local config = { split_side = "right", split_width_percentage = 0.3 }

      -- Create a terminal
      native_provider.open(cmd_string, env_table, config)
      local initial_bufnr = native_provider.get_active_bufnr()
      local mock_state = _G.get_mock_state()

      -- Find the terminal window
      local terminal_winid = nil
      for winid, win in pairs(mock_state.windows) do
        if win.bufnr == initial_bufnr then
          terminal_winid = winid
          break
        end
      end

      -- Mock being in the terminal window
      mock_state.current_win = terminal_winid

      -- Focus toggle should hide the terminal
      native_provider.focus_toggle(cmd_string, env_table, config)

      -- Should have hidden the terminal
      assert.is_nil(mock_state.windows[terminal_winid])
    end)
  end)
end)
