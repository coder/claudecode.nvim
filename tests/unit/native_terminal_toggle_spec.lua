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
      windows = { [1] = { bufnr = 0 } },
      current_win = 1,
      next_bufnr = 1,
      next_winid = 1000,
      next_jobid = 10000,
      buffer_options = {},
      bufenter_autocmd = nil,
      running_jobs = {},
      pending_writes = {},
      exiting_jobs = {},
      autocmds = {},
      waited_ms = 0,
    }

    local function enter_buf(winid, bufnr)
      mock_state.windows[winid].bufnr = bufnr
      if mock_state.bufenter_autocmd then
        mock_state.bufenter_autocmd(winid, bufnr)
      end
    end

    local function window_count()
      local count = 0
      for _ in pairs(mock_state.windows) do
        count = count + 1
      end
      return count
    end

    local function new_buffer(listed)
      local bufnr = mock_state.next_bufnr
      mock_state.next_bufnr = mock_state.next_bufnr + 1
      mock_state.buffers[bufnr] = { name = "", options = { modified = false, buflisted = listed } }
      return bufnr
    end

    -- Neovim does not run a handler that another handler adds while TermClose fires.
    function mock_state.fire_term_close(bufnr)
      for _, autocmd in ipairs({ unpack(mock_state.autocmds) }) do
        -- A buffer-local autocmd is gone once an earlier handler deleted its buffer.
        local applies = autocmd.buffer == nil or (autocmd.buffer == bufnr and mock_state.buffers[bufnr])
        if autocmd.event == "TermClose" and applies then
          autocmd.callback({ buf = bufnr })
        end
      end
    end

    -- Neovim fires TermClose and then calls on_exit, both while the buffer still exists.
    function mock_state.exit_job(bufnr)
      local buf = mock_state.buffers[bufnr]
      mock_state.running_jobs[buf.jobid] = nil
      mock_state.fire_term_close(bufnr)
      if buf.on_exit then
        buf.on_exit(buf.jobid, 0, "exit")
      end
    end

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
        nvim_list_tabpages = function()
          return { 1 }
        end,
        nvim_win_get_config = function(winid)
          return { relative = mock_state.windows[winid].relative or "" }
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
          if not win then
            error("Invalid window id: " .. tostring(winid))
          end
          return win.bufnr
        end,
        nvim_win_close = function(winid, force)
          if type(winid) ~= "number" then
            error("Invalid 'win': Expected Lua number")
          end
          if not mock_state.windows[winid] then
            error("Invalid window id: " .. winid)
          end
          if window_count() == 1 then
            error("Vim:E444: Cannot close last window")
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
              -- Neovim keeps the last window and shows another buffer in it.
              if window_count() == 1 then
                win.bufnr = new_buffer(true)
              else
                mock_state.windows[winid] = nil
              end
            end
          end
          if buf.jobid then
            mock_state.running_jobs[buf.jobid] = nil
          end
          mock_state.buffers[bufnr] = nil
        end,
        nvim_create_autocmd = function(event, opts)
          table.insert(
            mock_state.autocmds,
            { event = event, buffer = opts.buffer, group = opts.group, callback = opts.callback }
          )
        end,
        -- Group names are global, so a reloaded module gets the same group back.
        nvim_create_augroup = function(name, opts)
          mock_state.augroups = mock_state.augroups or {}
          if not mock_state.augroups[name] then
            mock_state.next_augroup = (mock_state.next_augroup or 0) + 1
            mock_state.augroups[name] = mock_state.next_augroup
          end
          local group = mock_state.augroups[name]
          if opts and opts.clear then
            mock_vim.api.nvim_clear_autocmds({ group = group })
          end
          return group
        end,
        nvim_clear_autocmds = function(opts)
          local kept = {}
          for _, autocmd in ipairs(mock_state.autocmds) do
            local matches = (opts.group == nil or autocmd.group == opts.group)
              and (opts.buffer == nil or autocmd.buffer == opts.buffer)
              and (opts.event == nil or autocmd.event == opts.event)
            if not matches then
              table.insert(kept, autocmd)
            end
          end
          mock_state.autocmds = kept
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
          if not mock_state.buffers[bufnr] then
            error("Invalid buffer id: " .. tostring(bufnr))
          end
          if mock_state.windows[winid] then
            enter_buf(winid, bufnr)
          end
        end,
        nvim_create_buf = function(listed, _scratch)
          return new_buffer(listed)
        end,
        -- Mirrors Neovim: a temporary window when no window shows bufnr, and a raised error comes back rewrapped.
        nvim_buf_call = function(bufnr, fn)
          if not mock_state.buffers[bufnr] then
            error("Invalid buffer id: " .. tostring(bufnr))
          end
          local saved_win = mock_state.current_win
          local target_win = nil
          if mock_state.windows[saved_win] and mock_state.windows[saved_win].bufnr == bufnr then
            target_win = saved_win
          else
            for winid, win in pairs(mock_state.windows) do
              if win.bufnr == bufnr then
                target_win = winid
                break
              end
            end
          end
          local temp_win = nil
          if not target_win then
            temp_win = mock_state.next_winid
            mock_state.next_winid = mock_state.next_winid + 1
            mock_state.windows[temp_win] = { bufnr = bufnr }
            target_win = temp_win
          end
          mock_state.current_win = target_win
          local ok, result = pcall(fn)
          mock_state.current_win = saved_win
          if temp_win then
            mock_state.windows[temp_win] = nil
          end
          if not ok then
            error("Lua: " .. tostring(result) .. "\nstack traceback:\n\t[C]: in function 'nvim_buf_call'", 0)
          end
          return result
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
          mock_state.buffers[bufnr] = { name = "", options = { modified = false, buflisted = true } }
          if mock_state.windows[mock_state.current_win] then
            enter_buf(mock_state.current_win, bufnr)
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

          local win = mock_state.windows[mock_state.current_win]
          local buf = win and mock_state.buffers[win.bufnr]
          assert(buf, "termopen needs a current buffer")
          buf.name = "term://claude"
          buf.options.buftype = "terminal"
          buf.options.channel = jobid
          buf.vars = buf.vars or {}
          buf.vars.terminal_job_id = jobid
          buf.jobid = jobid
          buf.on_exit = opts.on_exit
          mock_state.running_jobs[jobid] = true

          -- TermOpen fires before termopen returns. Autocmds do not nest, so a nested termopen fires none.
          if not mock_state.in_term_open then
            mock_state.in_term_open = true
            for _, autocmd in ipairs({ unpack(mock_state.autocmds) }) do
              if autocmd.event == "TermOpen" then
                autocmd.callback({ buf = win.bufnr })
              end
            end
            mock_state.in_term_open = false
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
        -- Neovim raises E900 for a job that exited or that jobstop already stopped.
        jobpid = function(id)
          if not mock_state.running_jobs[id] then
            error("Vim:E900: Invalid channel id")
          end
          return 40000 + id
        end,
      },
      -- A stopped job exits only when the event loop runs. Its pending writes end first, then TermClose fires.
      -- A condition that stays false blocks for the whole timeout.
      wait = function(timeout, condition)
        for _, id in ipairs(mock_state.exiting_jobs) do
          mock_state.pending_writes[id] = nil
          local exited = {}
          for bufnr, buf in pairs(mock_state.buffers) do
            if buf.jobid == id then
              table.insert(exited, bufnr)
            end
          end
          for _, bufnr in ipairs(exited) do
            mock_state.exit_job(bufnr)
          end
        end
        mock_state.exiting_jobs = {}
        local met = condition()
        if not met then
          mock_state.waited_ms = mock_state.waited_ms + timeout
        end
        return met
      end,
      schedule = function(callback)
        callback() -- Execute immediately in tests
      end,
      b = setmetatable({}, {
        __index = function(_, bufnr)
          local buf = mock_state.buffers[bufnr]
          if not buf then
            error("Invalid buffer id: " .. tostring(bufnr))
          end
          return setmetatable({}, {
            __index = function(_, name)
              return buf.vars and buf.vars[name]
            end,
            __newindex = function(_, name, value)
              buf.vars = buf.vars or {}
              buf.vars[name] = value
            end,
          })
        end,
      }),
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

  describe("termopen success", function()
    it("runs Claude in a listed terminal buffer shown in the split and closes it on exit", function()
      local mock_state = _G.get_mock_state()
      mock_state.windows[1] = { bufnr = 0 }
      mock_state.current_win = 1

      native_provider.open(
        "claude",
        {},
        { split_side = "right", split_width_percentage = 0.3, auto_close = true },
        true
      )

      local active = native_provider.get_active_bufnr()
      local buf = mock_state.buffers[active]
      assert.are.equal("terminal", buf.options.buftype)
      assert.are.equal("hide", buf.options.bufhidden)
      assert.is_true(buf.options.buflisted)
      local split = mock_state.current_win
      assert.are_not.equal(1, split)
      assert.are.equal(active, mock_state.windows[split].bufnr)

      buf.on_exit(buf.jobid, 0, "exit")

      assert.is_nil(native_provider.get_active_bufnr())
      assert.is_nil(mock_state.windows[split])
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
    local entries = {
      open = function(config)
        native_provider.open("claude", {}, config, true)
      end,
      simple_toggle = function(config)
        native_provider.simple_toggle("claude", {}, config)
      end,
      focus_toggle = function(config)
        native_provider.focus_toggle("claude", {}, config)
      end,
    }
    for _, failure in ipairs(failures) do
      for entry_name, start in pairs(entries) do
        it(
          "closes the split, deletes its buffer, and sends one notice when termopen "
            .. failure.name
            .. " ("
            .. entry_name
            .. ")",
          function()
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

            start({ split_side = "right", split_width_percentage = 0.3 })

            assert.is_nil(native_provider.get_active_bufnr())
            assert.are.equal(1, mock_state.current_win)
            local open_windows = {}
            for winid in pairs(mock_state.windows) do
              table.insert(open_windows, winid)
            end
            assert.are.same({ 1 }, open_windows)
            assert.are.same({}, mock_state.buffers)
            assert.are.same({ { msg = failure.message, level = 4 } }, notified)
          end
        )
      end
    end
  end)

  describe("an autocmd swaps another plugin's empty buffer into the new split", function()
    local plugin_bufnr = 99
    local plugin_buffer
    local mock_state

    before_each(function()
      mock_state = _G.get_mock_state()
      mock_state.windows[1] = { bufnr = 0 }
      mock_state.current_win = 1
      plugin_buffer = { name = "", options = { modified = false, buftype = "nofile" } }
      mock_state.buffers[plugin_bufnr] = plugin_buffer
      local swapped = false
      mock_state.bufenter_autocmd = function(winid, bufnr)
        if not swapped and winid ~= 1 and bufnr ~= plugin_bufnr then
          swapped = true
          mock_state.windows[winid].bufnr = plugin_bufnr
        end
      end
      mock_vim.api.nvim_buf_delete = function(bufnr)
        mock_state.buffers[bufnr] = nil
      end
      mock_vim.notify = function() end
      mock_vim.log = { levels = { ERROR = 4 } }
    end)

    it("keeps that buffer and deletes only its own when termopen fails", function()
      mock_vim.fn.termopen = function()
        error("Vim:E475: Invalid value for argument cmd: 'claude' is not executable", 0)
      end

      native_provider.open("claude", {}, { split_side = "right", split_width_percentage = 0.3 }, true)

      assert.are.same({ [plugin_bufnr] = plugin_buffer }, mock_state.buffers)
      assert.are.same({ name = "", options = { modified = false, buftype = "nofile" } }, plugin_buffer)
    end)

    it("closes the split and sends one notice when the autocmd also wipes its buffer", function()
      mock_state.bufenter_autocmd = function(winid, bufnr)
        if winid ~= 1 and bufnr ~= plugin_bufnr then
          mock_state.windows[winid].bufnr = plugin_bufnr
          mock_state.buffers[bufnr] = nil
        end
      end
      local notified = {}
      mock_vim.notify = function(msg, level)
        table.insert(notified, { msg = msg, level = level })
      end

      native_provider.open("claude", {}, { split_side = "right", split_width_percentage = 0.3 }, true)

      assert.is_nil(native_provider.get_active_bufnr())
      assert.are.equal(1, mock_state.current_win)
      local open_windows = {}
      for winid in pairs(mock_state.windows) do
        table.insert(open_windows, winid)
      end
      assert.are.same({ 1 }, open_windows)
      assert.are.same({ [plugin_bufnr] = plugin_buffer }, mock_state.buffers)
      assert.are.same({
        { msg = "Failed to open native terminal. Its buffer was deleted before termopen ran.", level = 4 },
      }, notified)
    end)

    it("runs Claude in its own buffer and shows it in the split when termopen succeeds", function()
      native_provider.open("claude", {}, { split_side = "right", split_width_percentage = 0.3 }, true)

      local active = native_provider.get_active_bufnr()
      assert.are_not.equal(plugin_bufnr, active)
      assert.are.equal("terminal", mock_state.buffers[active].options.buftype)
      assert.are.equal(active, mock_state.windows[mock_state.current_win].bufnr)
      assert.are.same({ name = "", options = { modified = false, buftype = "nofile" } }, plugin_buffer)
    end)
  end)

  describe("a TermOpen autocmd wipes the new terminal buffer", function()
    local plugin_bufnr = 99
    local mock_state
    local notified

    local function on_termopen(autocmd)
      local termopen = mock_vim.fn.termopen
      mock_vim.fn.termopen = function(cmd, opts)
        local job = termopen(cmd, opts)
        autocmd(mock_vim.api.nvim_get_current_buf())
        return job
      end
    end

    -- Mirrors :bwipeout! on a terminal buffer, which also stops its job and closes the windows that show it.
    local function wipe(bufnr)
      mock_vim.api.nvim_buf_delete(bufnr, { force = true })
    end

    before_each(function()
      mock_state = _G.get_mock_state()
      mock_state.windows[1] = { bufnr = 0 }
      mock_state.current_win = 1
      notified = {}
      mock_vim.notify = function(msg, level)
        table.insert(notified, { msg = msg, level = level })
      end
      mock_vim.log = { levels = { ERROR = 4 } }
    end)

    local function assert_clean_failure()
      assert.is_nil(native_provider.get_active_bufnr())
      assert.are.equal(1, mock_state.current_win)
      local open_windows = {}
      for winid in pairs(mock_state.windows) do
        table.insert(open_windows, winid)
      end
      assert.are.same({ 1 }, open_windows)
      assert.are.same({}, mock_state.running_jobs)
      assert.are.same({
        { msg = "Failed to open native terminal. Its buffer was deleted after termopen started.", level = 4 },
      }, notified)
    end

    it("restores the original window and sends one notice when the wipe also closed the split", function()
      on_termopen(wipe)

      native_provider.open("claude", {}, { split_side = "right", split_width_percentage = 0.3 }, true)

      assert_clean_failure()
      assert.are.same({}, mock_state.buffers)
    end)

    it("closes the split and keeps the buffer the autocmd swapped in", function()
      local plugin_buffer = { name = "", options = { modified = false, buftype = "nofile" } }
      mock_state.buffers[plugin_bufnr] = plugin_buffer
      on_termopen(function(bufnr)
        mock_state.windows[mock_state.current_win].bufnr = plugin_bufnr
        wipe(bufnr)
      end)

      native_provider.open("claude", {}, { split_side = "right", split_width_percentage = 0.3 }, true)

      assert_clean_failure()
      assert.are.same({ [plugin_bufnr] = plugin_buffer }, mock_state.buffers)
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

    it("should close cleanly when a user TermClose autocmd already deleted the buffer", function()
      local mock_state = _G.get_mock_state()
      mock_vim.api.nvim_create_autocmd("TermClose", {
        callback = function(args)
          mock_vim.api.nvim_buf_delete(args.buf, { force = true })
        end,
      })
      native_provider.open("claude", {}, config)
      local terminal_bufnr = native_provider.get_active_bufnr()
      local terminal_jobid = mock_state.buffers[terminal_bufnr].jobid

      native_provider.close()
      assert.is_nil(mock_state.running_jobs[terminal_jobid])
      assert.is_nil(mock_state.buffers[terminal_bufnr])
      assert.is_nil(native_provider.get_active_bufnr())
    end)

    it("should close without waiting when a TermClose autocmd calls it after the job exited", function()
      local mock_state = _G.get_mock_state()
      native_provider.open("claude", {}, config)
      local terminal_bufnr = native_provider.get_active_bufnr()
      local terminal_jobid = mock_state.buffers[terminal_bufnr].jobid
      mock_vim.api.nvim_create_autocmd("TermClose", {
        callback = function()
          native_provider.close()
        end,
      })

      mock_state.exit_job(terminal_bufnr)

      assert.are.equal(0, mock_state.waited_ms)
      assert.is_nil(mock_state.running_jobs[terminal_jobid])
      assert.is_nil(mock_state.buffers[terminal_bufnr])
      assert.is_nil(native_provider.get_active_bufnr())
    end)

    it("should start a new terminal when an open scheduled before close runs during the close wait", function()
      local mock_state = _G.get_mock_state()
      native_provider.open("claude", {}, config)
      local closing_bufnr = native_provider.get_active_bufnr()
      local closing_jobid = mock_state.buffers[closing_bufnr].jobid
      -- vim.wait runs the event loop, so a callback scheduled before close runs while close waits.
      local scheduled = {}
      mock_vim.schedule = function(callback)
        table.insert(scheduled, callback)
      end
      local wait = mock_vim.wait
      mock_vim.wait = function(...)
        local callbacks = scheduled
        scheduled = {}
        for _, callback in ipairs(callbacks) do
          callback()
        end
        return wait(...)
      end

      mock_vim.schedule(function()
        native_provider.open("claude", {}, config)
      end)
      native_provider.close()

      assert.is_nil(mock_state.buffers[closing_bufnr])
      assert.is_nil(mock_state.running_jobs[closing_jobid])
      local active = native_provider.get_active_bufnr()
      assert.is_not_nil(active)
      assert.are.equal(1, windows_showing(active))
      assert.is_true(mock_state.running_jobs[mock_state.buffers[active].jobid])
    end)

    local entries = {
      open = function()
        native_provider.open("claude", {}, config)
      end,
      simple_toggle = function()
        native_provider.simple_toggle("claude", {}, config)
      end,
      focus_toggle = function()
        native_provider.focus_toggle("claude", {}, config)
      end,
    }
    for entry_name, start in pairs(entries) do
      it("should not adopt an unrelated terminal whose name contains claude (" .. entry_name .. ")", function()
        local mock_state = _G.get_mock_state()
        local shell_bufnr, shell_winid, shell_jobid = 50, 500, 5000
        mock_state.buffers[shell_bufnr] = {
          name = "term://~/src/claudecode.nvim//4242:/bin/zsh",
          options = { buftype = "terminal" },
          vars = { terminal_job_id = shell_jobid },
          jobid = shell_jobid,
        }
        mock_state.windows[shell_winid] = { bufnr = shell_bufnr }
        mock_state.running_jobs[shell_jobid] = true

        start()
        local active = native_provider.get_active_bufnr()
        assert.are_not.equal(shell_bufnr, active)
        assert.are.equal(1, windows_showing(active))

        native_provider.close()
        assert.is_true(mock_state.running_jobs[shell_jobid])
        assert.are.equal(1, windows_showing(shell_bufnr))
        assert.is_nil(native_provider.get_active_bufnr())
      end)
    end

    it("should not start a second terminal when a TermOpen autocmd calls open", function()
      local mock_state = _G.get_mock_state()
      mock_vim.api.nvim_create_autocmd("TermOpen", {
        callback = function()
          native_provider.open("claude", {}, config)
        end,
      })

      native_provider.open("claude", {}, config)

      local running = {}
      for id in pairs(mock_state.running_jobs) do
        table.insert(running, id)
      end
      assert.are.equal(1, #running)
      assert.are.equal(running[1], mock_state.buffers[native_provider.get_active_bufnr()].jobid)
    end)

    it("should start a new terminal instead of adopting one whose job exited", function()
      local mock_state = _G.get_mock_state()
      local keep_open = { split_side = "right", split_width_percentage = 0.3, auto_close = false }
      native_provider.open("claude", {}, keep_open)
      local exited_bufnr = native_provider.get_active_bufnr()
      mock_state.exit_job(exited_bufnr)
      assert.are.equal(1, windows_showing(exited_bufnr))

      native_provider.open("claude", {}, keep_open)

      local active = native_provider.get_active_bufnr()
      assert.are_not.equal(exited_bufnr, active)
      assert.is_true(mock_state.running_jobs[mock_state.buffers[active].jobid])
    end)

    local function keep_only_window_of(bufnr)
      local mock_state = _G.get_mock_state()
      for winid, win in pairs(mock_state.windows) do
        if win.bufnr ~= bufnr then
          mock_state.windows[winid] = nil
        end
      end
    end

    it("should keep the only window without an error when the job exits on its own", function()
      local mock_state = _G.get_mock_state()
      local auto_close = { split_side = "right", split_width_percentage = 0.3, auto_close = true }
      native_provider.open("claude", {}, auto_close)
      local terminal_bufnr = native_provider.get_active_bufnr()
      keep_only_window_of(terminal_bufnr)

      mock_state.exit_job(terminal_bufnr)

      assert.are.equal(1, windows_showing(terminal_bufnr))
      assert.is_nil(native_provider.get_active_bufnr())
    end)

    it("should stop the job of a terminal it adopts after a module reload, even in the only window", function()
      local mock_state = _G.get_mock_state()
      -- The module instance that started the job still runs its on_exit, and auto_close closes the window.
      local auto_close = { split_side = "right", split_width_percentage = 0.3, auto_close = true }
      native_provider.open("claude", {}, auto_close)
      local terminal_bufnr = native_provider.get_active_bufnr()
      local terminal_jobid = mock_state.buffers[terminal_bufnr].jobid
      keep_only_window_of(terminal_bufnr)
      package.loaded["claudecode.terminal.native"] = nil
      native_provider = require("claudecode.terminal.native")
      native_provider.setup({})

      native_provider.open("claude", {}, auto_close)
      assert.are.equal(terminal_bufnr, native_provider.get_active_bufnr())

      native_provider.close()
      assert.is_nil(mock_state.running_jobs[terminal_jobid])
      assert.is_nil(mock_state.buffers[terminal_bufnr])
      local remaining = {}
      for winid in pairs(mock_state.windows) do
        table.insert(remaining, winid)
      end
      assert.are.equal(1, #remaining)
      assert.is_nil(native_provider.get_active_bufnr())
    end)

    -- The reloaded module gets the same terminal config from setup that the plugin passes in.
    local function start_then_reload_and_adopt(term_config)
      native_provider.open("claude", {}, term_config)
      local terminal_bufnr = native_provider.get_active_bufnr()
      package.loaded["claudecode.terminal.native"] = nil
      native_provider = require("claudecode.terminal.native")
      native_provider.setup({ auto_close = term_config.auto_close })
      native_provider.open("claude", {}, term_config)
      assert.are.equal(terminal_bufnr, native_provider.get_active_bufnr())
      return terminal_bufnr
    end

    for _, auto_close in ipairs({ true, false }) do
      it(
        "should start a new terminal after a terminal it adopted after a module reload exits (auto_close="
          .. tostring(auto_close)
          .. ")",
        function()
          local mock_state = _G.get_mock_state()
          local term_config = { split_side = "right", split_width_percentage = 0.3, auto_close = auto_close }
          local exited_bufnr = start_then_reload_and_adopt(term_config)

          mock_state.exit_job(exited_bufnr)
          native_provider.simple_toggle("claude", {}, term_config)

          local active = native_provider.get_active_bufnr()
          assert.are_not.equal(exited_bufnr, active)
          assert.are.equal(1, windows_showing(active))
          assert.is_true(mock_state.running_jobs[mock_state.buffers[active].jobid])
        end
      )
    end

    for _, auto_close in ipairs({ true, false }) do
      it(
        "should start a new terminal when a TermClose autocmd opens it after a module reload (auto_close="
          .. tostring(auto_close)
          .. ")",
        function()
          local mock_state = _G.get_mock_state()
          local term_config = { split_side = "right", split_width_percentage = 0.3, auto_close = auto_close }
          native_provider.open("claude", {}, term_config)
          local exited_bufnr = native_provider.get_active_bufnr()
          package.loaded["claudecode.terminal.native"] = nil
          native_provider = require("claudecode.terminal.native")
          native_provider.setup({ auto_close = auto_close })
          -- The reloaded module opens for the first time here, after the exit and before the old on_exit runs.
          mock_vim.api.nvim_create_autocmd("TermClose", {
            callback = function(args)
              if args.buf == exited_bufnr then
                native_provider.open("claude", {}, term_config)
              end
            end,
          })

          mock_state.exit_job(exited_bufnr)

          local active = native_provider.get_active_bufnr()
          assert.are_not.equal(exited_bufnr, active)
          assert.is_true(mock_state.running_jobs[mock_state.buffers[active].jobid])
        end
      )
    end

    it("should keep one exit handler on a terminal it adopts again after each reload", function()
      local mock_state = _G.get_mock_state()
      local term_config = { split_side = "right", split_width_percentage = 0.3, auto_close = true }
      local terminal_bufnr = start_then_reload_and_adopt(term_config)
      for _ = 1, 2 do
        package.loaded["claudecode.terminal.native"] = nil
        native_provider = require("claudecode.terminal.native")
        native_provider.setup({ auto_close = true })
        native_provider.open("claude", {}, term_config)
        assert.are.equal(terminal_bufnr, native_provider.get_active_bufnr())
      end

      local handlers = 0
      for _, autocmd in ipairs(mock_state.autocmds) do
        if autocmd.event == "TermClose" and autocmd.buffer == terminal_bufnr then
          handlers = handlers + 1
        end
      end
      assert.are.equal(1, handlers)

      mock_state.exit_job(terminal_bufnr)
      assert.is_nil(native_provider.get_active_bufnr())
      assert.are.equal(0, windows_showing(terminal_bufnr))
    end)

    it("should close the window of an adopted terminal it showed again when the job exits with auto_close", function()
      local mock_state = _G.get_mock_state()
      local term_config = { split_side = "right", split_width_percentage = 0.3, auto_close = true }
      local exited_bufnr = start_then_reload_and_adopt(term_config)
      native_provider.simple_toggle("claude", {}, term_config)
      native_provider.simple_toggle("claude", {}, term_config)
      assert.are.equal(1, windows_showing(exited_bufnr))

      mock_state.exit_job(exited_bufnr)

      assert.are.equal(0, windows_showing(exited_bufnr))
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
