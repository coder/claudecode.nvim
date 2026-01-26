-- luacheck: globals expect
require("tests.busted_setup")

describe("Selection WinEnter event handling", function()
  local selection_module
  local mock_server
  local mock_vim

  local function setup_mocks()
    package.loaded["claudecode.selection"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.session"] = nil

    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
    }

    -- Mock terminal
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return nil -- No active terminal by default
      end,
    }

    -- Mock session manager
    package.loaded["claudecode.session"] = {
      get_active_session_id = function()
        return nil
      end,
      update_selection = function() end,
      get_selection = function()
        return nil
      end,
    }

    -- Extend the existing vim mock
    mock_vim = _G.vim or {}

    -- Track defer_fn calls
    mock_vim._defer_fn_calls = {}
    mock_vim.defer_fn = function(fn, timeout)
      table.insert(mock_vim._defer_fn_calls, { fn = fn, timeout = timeout })
      -- Execute immediately for testing
      fn()
    end

    -- Track timer operations
    mock_vim.loop = mock_vim.loop or {}
    mock_vim._timers = {}
    mock_vim._timer_stops = {}

    mock_vim.loop.timer_stop = function(timer)
      table.insert(mock_vim._timer_stops, timer)
      return true
    end

    mock_vim.loop.new_timer = function()
      local timer = {
        start = function() end,
        stop = function() end,
        close = function() end,
      }
      table.insert(mock_vim._timers, timer)
      return timer
    end

    mock_vim.loop.now = function()
      return os.time() * 1000
    end

    -- Mock API functions
    mock_vim.api = mock_vim.api or {}
    mock_vim._autocmd_events = {}

    mock_vim.api.nvim_create_augroup = function(name, opts)
      return name
    end

    mock_vim.api.nvim_create_autocmd = function(events, opts)
      local events_list = type(events) == "table" and events or { events }
      for _, event in ipairs(events_list) do
        mock_vim._autocmd_events[event] = opts.callback
      end
      return 1
    end

    mock_vim.api.nvim_clear_autocmds = function() end

    mock_vim.api.nvim_get_mode = function()
      return { mode = "n" } -- Default to normal mode
    end

    mock_vim.api.nvim_get_current_buf = function()
      return 1
    end

    mock_vim.api.nvim_buf_get_name = function(bufnr)
      return "/test/file.lua"
    end

    mock_vim.api.nvim_win_get_cursor = function(winid)
      return { 1, 0 }
    end

    mock_vim.schedule_wrap = function(fn)
      return fn
    end

    mock_vim.schedule = function(fn)
      fn()
    end

    mock_vim.deepcopy = function(t)
      if type(t) ~= "table" then
        return t
      end
      local copy = {}
      for k, v in pairs(t) do
        copy[k] = mock_vim.deepcopy(v)
      end
      return copy
    end

    _G.vim = mock_vim
  end

  before_each(function()
    setup_mocks()

    mock_server = {
      broadcast = function()
        return true
      end,
      send_to_active_session = function()
        return false
      end,
    }

    selection_module = require("claudecode.selection")
  end)

  after_each(function()
    if selection_module and selection_module.state.tracking_enabled then
      selection_module.disable()
    end
    mock_vim._defer_fn_calls = {}
    mock_vim._timer_stops = {}
    mock_vim._autocmd_events = {}
  end)

  describe("WinEnter autocommand registration", function()
    it("should register WinEnter autocommand when selection tracking is enabled", function()
      selection_module.enable(mock_server, 50)

      expect(mock_vim._autocmd_events["WinEnter"]).not_to_be_nil()
    end)

    it("should not have WinEnter autocommand before enabling", function()
      -- The autocommands are created inside _create_autocommands which is called by enable
      expect(mock_vim._autocmd_events["WinEnter"]).to_be_nil()
    end)

    it("should register all expected autocommands", function()
      selection_module.enable(mock_server, 50)

      expect(mock_vim._autocmd_events["CursorMoved"]).not_to_be_nil()
      expect(mock_vim._autocmd_events["CursorMovedI"]).not_to_be_nil()
      expect(mock_vim._autocmd_events["BufEnter"]).not_to_be_nil()
      expect(mock_vim._autocmd_events["WinEnter"]).not_to_be_nil()
      expect(mock_vim._autocmd_events["ModeChanged"]).not_to_be_nil()
      expect(mock_vim._autocmd_events["TextChanged"]).not_to_be_nil()
    end)
  end)

  describe("on_win_enter handler", function()
    it("should call update_selection when tracking is enabled", function()
      selection_module.enable(mock_server, 50)

      local update_called = false
      local original_update = selection_module.update_selection
      selection_module.update_selection = function()
        update_called = true
        original_update()
      end

      selection_module.on_win_enter()

      expect(update_called).to_be_true()

      selection_module.update_selection = original_update
    end)

    it("should not call update_selection when tracking is disabled", function()
      selection_module.enable(mock_server, 50)
      selection_module.disable()

      local update_called = false
      local original_update = selection_module.update_selection
      selection_module.update_selection = function()
        update_called = true
      end

      selection_module.on_win_enter()

      expect(update_called).to_be_false()

      selection_module.update_selection = original_update
    end)

    it("should cancel pending debounce timer", function()
      selection_module.enable(mock_server, 50)

      -- Simulate a pending debounce timer
      local mock_timer = { stopped = false }
      selection_module.state.debounce_timer = mock_timer

      selection_module.on_win_enter()

      -- Check that timer_stop was called
      expect(#mock_vim._timer_stops > 0).to_be_true()
      expect(selection_module.state.debounce_timer).to_be_nil()
    end)

    it("should use 10ms delay via defer_fn", function()
      selection_module.enable(mock_server, 50)

      mock_vim._defer_fn_calls = {}
      selection_module.on_win_enter()

      expect(#mock_vim._defer_fn_calls > 0).to_be_true()
      expect(mock_vim._defer_fn_calls[1].timeout).to_be(10)
    end)
  end)

  describe("WinEnter callback invocation", function()
    it("should invoke on_win_enter when WinEnter event fires", function()
      selection_module.enable(mock_server, 50)

      local on_win_enter_called = false
      local original = selection_module.on_win_enter
      selection_module.on_win_enter = function()
        on_win_enter_called = true
        original()
      end

      -- Simulate WinEnter event
      local callback = mock_vim._autocmd_events["WinEnter"]
      expect(callback).not_to_be_nil()
      callback()

      expect(on_win_enter_called).to_be_true()

      selection_module.on_win_enter = original
    end)
  end)

  describe("keyboard navigation scenarios", function()
    it("should update file reference when navigating to window with different buffer", function()
      selection_module.enable(mock_server, 50)

      local selections_sent = {}
      mock_server.broadcast = function(event, data)
        if event == "selection_changed" then
          table.insert(selections_sent, data)
        end
        return true
      end

      -- Simulate first window with file1
      mock_vim.api.nvim_buf_get_name = function()
        return "/test/file1.lua"
      end
      selection_module.on_win_enter()

      -- Simulate navigating to second window with file2
      mock_vim.api.nvim_buf_get_name = function()
        return "/test/file2.lua"
      end
      selection_module.on_win_enter()

      -- Should have sent updates for both files
      expect(#selections_sent >= 1).to_be_true()
      local last_selection = selections_sent[#selections_sent]
      expect(last_selection.filePath).to_be("/test/file2.lua")
    end)

    it("should update when navigating to window with same buffer but different cursor", function()
      selection_module.enable(mock_server, 50)

      local selections_sent = {}
      mock_server.broadcast = function(event, data)
        if event == "selection_changed" then
          table.insert(selections_sent, data)
        end
        return true
      end

      -- First window position
      mock_vim.api.nvim_win_get_cursor = function()
        return { 1, 0 }
      end
      selection_module.on_win_enter()

      -- Second window position (same file, different cursor)
      mock_vim.api.nvim_win_get_cursor = function()
        return { 10, 5 }
      end
      selection_module.on_win_enter()

      -- Should have sent updates for position changes
      expect(#selections_sent >= 1).to_be_true()
    end)

    it("should not cause race conditions with rapid window switching", function()
      selection_module.enable(mock_server, 50)

      local error_occurred = false
      local original_update = selection_module.update_selection

      selection_module.update_selection = function()
        if error_occurred then
          return
        end
        local success = pcall(original_update)
        if not success then
          error_occurred = true
        end
      end

      -- Simulate rapid window switching
      for i = 1, 20 do
        mock_vim.api.nvim_buf_get_name = function()
          return "/test/file" .. i .. ".lua"
        end
        selection_module.on_win_enter()
      end

      expect(error_occurred).to_be_false()

      selection_module.update_selection = original_update
    end)
  end)

  describe("integration with existing handlers", function()
    it("should not interfere with mouse handler behavior", function()
      selection_module.enable(mock_server, 50)

      local selections_sent = {}
      mock_server.broadcast = function(event, data)
        if event == "selection_changed" then
          table.insert(selections_sent, data)
        end
        return true
      end

      -- Simulate WinEnter (keyboard navigation)
      selection_module.on_win_enter()
      local count_after_win_enter = #selections_sent

      -- Simulate update_selection directly (like mouse handler does)
      selection_module.update_selection()
      local count_after_mouse = #selections_sent

      -- Both should work independently
      expect(count_after_win_enter >= 1).to_be_true()
      -- Mouse update might not send if selection hasn't changed
      expect(count_after_mouse >= count_after_win_enter).to_be_true()
    end)

    it("should work alongside BufEnter events", function()
      selection_module.enable(mock_server, 50)

      -- Both WinEnter and BufEnter should have callbacks
      expect(mock_vim._autocmd_events["WinEnter"]).not_to_be_nil()
      expect(mock_vim._autocmd_events["BufEnter"]).not_to_be_nil()

      -- Both should be callable without errors
      local success1 = pcall(mock_vim._autocmd_events["WinEnter"])
      local success2 = pcall(mock_vim._autocmd_events["BufEnter"])

      expect(success1).to_be_true()
      expect(success2).to_be_true()
    end)
  end)

  describe("terminal buffer handling", function()
    it("should skip update when entering Claude terminal window", function()
      selection_module.enable(mock_server, 50)

      -- Mock terminal to return a Claude terminal buffer
      package.loaded["claudecode.terminal"].get_active_terminal_bufnr = function()
        return 1 -- Current buffer is the terminal
      end

      local selections_sent = {}
      mock_server.broadcast = function(event, data)
        if event == "selection_changed" then
          table.insert(selections_sent, data)
        end
        return true
      end

      -- Clear any previous selections
      selection_module.state.latest_selection = nil

      selection_module.on_win_enter()

      -- Should not send selection update for terminal
      expect(#selections_sent).to_be(0)
    end)

    it("should skip update when buffer name matches term://...claude pattern", function()
      selection_module.enable(mock_server, 50)

      mock_vim.api.nvim_buf_get_name = function()
        return "term://~/claude"
      end

      local selections_sent = {}
      mock_server.broadcast = function(event, data)
        if event == "selection_changed" then
          table.insert(selections_sent, data)
        end
        return true
      end

      -- Clear any previous selections
      selection_module.state.latest_selection = nil

      selection_module.on_win_enter()

      -- Should not send selection update for claude terminal
      expect(#selections_sent).to_be(0)
    end)
  end)
end)
