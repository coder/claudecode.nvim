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
      running_jobs = {},
      pending_writes = {},
      exiting_jobs = {},
      autocmds = {},
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
          if type(winid) ~= "number" then
            error("Invalid 'win': Expected Lua number")
          end
          if not mock_state.windows[winid] then
            error("Invalid window id: " .. winid)
          end
          mock_state.windows[winid] = nil
        end,
        nvim_buf_delete = function(bufnr, opts)
          local buf = mock_state.buffers[bufnr]
          if not buf then
            error("Invalid buffer id: " .. tostring(bufnr))
          end
          if mock_state.running_jobs[buf.jobid] and not (opts and opts.force) then
            error("Failed to unload buffer.")
          end
          if mock_state.pending_writes[buf.jobid] then
            error("Neovim hangs: terminal buffer deleted with a pending write (neovim/neovim#42508)")
          end
          for winid, win in pairs(mock_state.windows) do
            if win.bufnr == bufnr then
              mock_state.windows[winid] = nil
            end
          end
          if buf.jobid then
            mock_state.running_jobs[buf.jobid] = nil
          end
          mock_state.buffers[bufnr] = nil
        end,
        nvim_create_autocmd = function(event, opts)
          table.insert(mock_state.autocmds, { event = event, buffer = opts.buffer, callback = opts.callback })
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
          mock_state.buffers[bufnr] = { name = "", options = { modified = false } }
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
          mock_state.running_jobs[jobid] = true

          -- Set buffer in current window
          if mock_state.windows[mock_state.current_win] then
            mock_state.windows[mock_state.current_win].bufnr = bufnr
          end

          return jobid
        end,
        chansend = function(id, data)
          mock_state.pending_writes[id] = true
          return #data
        end,
        jobstop = function(id)
          if not mock_state.running_jobs[id] then
            return 0
          end
          mock_state.running_jobs[id] = nil
          table.insert(mock_state.exiting_jobs, id)
          return 1
        end,
      },
      -- A stopped job exits only when the event loop runs. Its pending writes end first, then TermClose fires.
      wait = function(_, condition)
        for _, id in ipairs(mock_state.exiting_jobs) do
          mock_state.pending_writes[id] = nil
          for bufnr, buf in pairs(mock_state.buffers) do
            if buf.jobid == id then
              for _, autocmd in ipairs(mock_state.autocmds) do
                if autocmd.event == "TermClose" and autocmd.buffer == bufnr then
                  autocmd.callback()
                end
              end
            end
          end
        end
        mock_state.exiting_jobs = {}
        return condition()
      end,
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
              local value = buf and buf.options and buf.options[option]
              if value == nil then
                return ""
              end
              return value
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

  describe("termopen failure", function()
    local e475 = "Vim:E475: Invalid value for argument cmd: 'claude' is not executable"
    local failures = {
      {
        name = "returns 0",
        termopen = function()
          return 0
        end,
        message = "Failed to open native terminal.",
      },
      {
        name = "returns -1",
        termopen = function()
          return -1
        end,
        message = "Failed to open native terminal.",
      },
      {
        name = "raises E475 for a command that is not executable",
        termopen = function()
          error(e475, 0)
        end,
        message = "Failed to open native terminal. " .. e475,
      },
    }
    for _, failure in ipairs(failures) do
      it("closes the split, deletes its buffer, and notifies once when termopen " .. failure.name, function()
        local mock_state = _G.get_mock_state()
        mock_state.windows[1] = { bufnr = 0 }
        mock_state.current_win = 1
        mock_vim.api.nvim_buf_delete = function(bufnr)
          mock_state.buffers[bufnr] = nil
        end
        local notified = {}
        mock_vim.notify = function(msg, level)
          table.insert(notified, { msg = msg, level = level })
        end
        mock_vim.log = { levels = { ERROR = 4 } }
        mock_vim.fn.termopen = failure.termopen

        native_provider.open("claude", {}, { split_side = "right", split_width_percentage = 0.3 }, true)

        assert.is_nil(native_provider.get_active_bufnr())
        assert.are.equal(1, mock_state.current_win)
        local open_windows = {}
        for winid in pairs(mock_state.windows) do
          table.insert(open_windows, winid)
        end
        assert.are.same({ 1 }, open_windows)
        assert.are.same({}, mock_state.buffers)
        assert.are.same({
          { msg = failure.message, level = 4 },
          { msg = "Failed to open Claude terminal using native fallback.", level = 4 },
        }, notified)
      end)
    end
  end)

  describe("termopen failure after an autocmd swaps the buffer", function()
    it("keeps a named, modified user buffer that an autocmd put in the new split", function()
      local mock_state = _G.get_mock_state()
      mock_state.windows[1] = { bufnr = 0 }
      mock_state.current_win = 1
      local user_bufnr = 99
      mock_state.buffers[user_bufnr] = { name = "/tmp/notes.txt", options = { modified = true } }
      local original_win_call = mock_vim.api.nvim_win_call
      mock_vim.api.nvim_win_call = function(winid, fn)
        local result = original_win_call(winid, fn)
        mock_state.windows[winid].bufnr = user_bufnr
        return result
      end
      local deleted = {}
      mock_vim.api.nvim_buf_delete = function(bufnr)
        table.insert(deleted, bufnr)
        mock_state.buffers[bufnr] = nil
      end
      mock_vim.notify = function() end
      mock_vim.log = { levels = { ERROR = 4 } }
      mock_vim.fn.termopen = function()
        error("Vim:E475: Invalid value for argument cmd: 'claude' is not executable", 0)
      end

      native_provider.open("claude", {}, { split_side = "right", split_width_percentage = 0.3 }, true)

      assert.are.same({}, deleted)
      assert.is_not_nil(mock_state.buffers[user_bufnr])
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
    local config = { split_side = "right", split_width_percentage = 0.3 }

    local function windows_showing(bufnr)
      local count = 0
      for _, win in pairs(_G.get_mock_state().windows) do
        if win.bufnr == bufnr then
          count = count + 1
        end
      end
      return count
    end

    it("should preserve process on toggle but kill on close", function()
      local mock_state = _G.get_mock_state()
      native_provider.open("claude", {}, config)
      local terminal_bufnr = native_provider.get_active_bufnr()
      local terminal_jobid = mock_state.buffers[terminal_bufnr].jobid

      native_provider.toggle("claude", {}, config)
      assert.are.equal(0, windows_showing(terminal_bufnr))
      assert.is_true(mock_state.running_jobs[terminal_jobid])

      native_provider.close()
      assert.is_nil(mock_state.running_jobs[terminal_jobid])
      assert.is_nil(mock_state.buffers[terminal_bufnr])
      assert.is_nil(native_provider.get_active_bufnr())
    end)

    it("should kill the process and close its window when closing a visible terminal", function()
      local mock_state = _G.get_mock_state()
      native_provider.open("claude", {}, config)
      local terminal_bufnr = native_provider.get_active_bufnr()
      local terminal_jobid = mock_state.buffers[terminal_bufnr].jobid
      assert.are.equal(1, windows_showing(terminal_bufnr))

      native_provider.close()
      assert.is_nil(mock_state.running_jobs[terminal_jobid])
      assert.is_nil(mock_state.buffers[terminal_bufnr])
      assert.are.equal(0, windows_showing(terminal_bufnr))
      assert.is_nil(native_provider.get_active_bufnr())
    end)

    it("should not delete the buffer while text sent to the process is still pending", function()
      local mock_state = _G.get_mock_state()
      native_provider.open("claude", {}, config)
      local terminal_bufnr = native_provider.get_active_bufnr()
      local terminal_jobid = mock_state.buffers[terminal_bufnr].jobid

      mock_vim.fn.chansend(terminal_jobid, "hello")
      native_provider.close()
      assert.is_nil(mock_state.running_jobs[terminal_jobid])
      assert.is_nil(mock_state.buffers[terminal_bufnr])
      assert.are.equal(0, windows_showing(terminal_bufnr))
    end)

    it("should close only the window of an adopted terminal and leave its process running", function()
      local mock_state = _G.get_mock_state()
      local shell_bufnr, shell_winid, shell_jobid = 50, 500, 5000
      mock_state.buffers[shell_bufnr] = {
        name = "term://~/src/claudecode.nvim//4242:/bin/zsh",
        options = { buftype = "terminal" },
        jobid = shell_jobid,
      }
      mock_state.windows[shell_winid] = { bufnr = shell_bufnr }
      mock_state.running_jobs[shell_jobid] = true

      native_provider.open("claude", {}, config)
      assert.are.equal(shell_bufnr, native_provider.get_active_bufnr())

      native_provider.close()
      assert.is_true(mock_state.running_jobs[shell_jobid])
      assert.is_not_nil(mock_state.buffers[shell_bufnr])
      assert.are.equal(0, windows_showing(shell_bufnr))
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
