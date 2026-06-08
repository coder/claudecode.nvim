if not _G.vim then
  local next_timer_id = 0

  _G.vim = { ---@type vim_global_api
    schedule_wrap = function(fn)
      return fn
    end,
    schedule = function(fn)
      fn()
    end,
    _buffers = {},
    _windows = {},
    _commands = {},
    _autocmds = {},
    _vars = {},
    _options = {},
    _current_mode = "n",

    api = {
      nvim_create_user_command = function(name, callback, opts)
        _G.vim._commands[name] = {
          callback = callback,
          opts = opts,
        }
      end,

      nvim_create_augroup = function(name, opts)
        _G.vim._autocmds[name] = {
          opts = opts,
          events = {},
        }
        return name
      end,

      nvim_create_autocmd = function(events, opts)
        local group = opts.group or "default"
        if not _G.vim._autocmds[group] then
          _G.vim._autocmds[group] = {
            opts = {},
            events = {},
          }
        end

        local id = #_G.vim._autocmds[group].events + 1
        _G.vim._autocmds[group].events[id] = {
          events = events,
          opts = opts,
        }

        return id
      end,

      nvim_clear_autocmds = function(opts)
        if opts.group then
          _G.vim._autocmds[opts.group] = nil
        end
      end,

      nvim_get_current_buf = function()
        return 1
      end,

      nvim_buf_get_name = function(bufnr)
        return _G.vim._buffers[bufnr] and _G.vim._buffers[bufnr].name or ""
      end,

      nvim_get_current_win = function()
        return 1
      end,

      nvim_win_get_cursor = function(winid)
        return _G.vim._windows[winid] and _G.vim._windows[winid].cursor or { 1, 0 }
      end,

      nvim_get_mode = function()
        return { mode = _G.vim._current_mode }
      end,

      nvim_buf_get_changedtick = function(_)
        return _G.vim._changedtick or 0
      end,

      nvim_buf_get_lines = function(bufnr, start, end_line, _strict) -- Prefix unused param with underscore
        if not _G.vim._buffers[bufnr] then
          return {}
        end

        local lines = _G.vim._buffers[bufnr].lines or {}
        local result = {}

        for i = start + 1, end_line do
          table.insert(result, lines[i] or "")
        end

        return result
      end,

      nvim_echo = function(chunks, history, opts)
        -- Just store the last echo message for testing
        _G.vim._last_echo = {
          chunks = chunks,
          history = history,
          opts = opts,
        }
      end,

      nvim_err_writeln = function(msg)
        _G.vim._last_error = msg
      end,
    },
    cmd = function() end, ---@type fun(command: string):nil
    fs = { remove = function() end }, ---@type vim_fs_module
    fn = { ---@type vim_fn_table
      bufnr = function(name)
        for bufnr, buf in pairs(_G.vim._buffers) do
          if buf.name == name then
            return bufnr
          end
        end
        return -1
      end,
      getpos = function(mark)
        -- Tests can override specific marks via _G.vim._marks (e.g. { ["'<"] = {0,1,1,0} }).
        if _G.vim._marks and _G.vim._marks[mark] then
          return _G.vim._marks[mark]
        end
        if mark == "'<" then
          return { 0, 1, 1, 0 }
        elseif mark == "'>" then
          return { 0, 5, 10, 0 }
        end
        return { 0, 0, 0, 0 }
      end,
      -- Last completed visual mode; tests set _G.vim._visualmode.
      visualmode = function()
        return _G.vim._visualmode or ""
      end,
      -- Add other vim.fn mocks as needed by selection tests
      mode = function()
        return _G.vim._current_mode or "n"
      end,
      delete = function(_, _)
        return 0
      end,
      filereadable = function(_)
        return 1
      end,
      fnamemodify = function(fname, _)
        return fname
      end,
      expand = function(s, _)
        return s
      end,
      getcwd = function()
        return "/mock/cwd"
      end,
      mkdir = function(_, _, _)
        return 1
      end,
      buflisted = function(_)
        return 1
      end,
      bufname = function(_)
        return "mockbuffer"
      end,
      win_getid = function()
        return 1
      end,
      win_gotoid = function(_)
        return true
      end,
      line = function(_)
        return 1
      end,
      col = function(_)
        return 1
      end,
      virtcol = function(_)
        return 1
      end,
      setpos = function(_, _)
        return true
      end,
      tempname = function()
        return "/tmp/mocktemp"
      end,
      globpath = function(_, _)
        return ""
      end,
      stdpath = function(_)
        return "/mock/stdpath"
      end,
      json_encode = function(_)
        return "{}"
      end,
      json_decode = function(_)
        return {}
      end,
      termopen = function(_, _)
        return 0
      end,
    },
    defer_fn = function(fn, _timeout) -- Prefix unused param with underscore
      -- For testing, we'll execute immediately
      fn()
    end,

    loop = {
      now = function()
        return 0
      end,
      new_timer = function()
        next_timer_id = next_timer_id + 1

        local timer = {
          _id = next_timer_id,
          _start_calls = 0,
          _stop_calls = 0,
          _close_calls = 0,
          _callback = nil,
        }

        function timer:start(timeout, repeat_interval, callback)
          self._start_calls = self._start_calls + 1
          self._timeout = timeout
          self._repeat_interval = repeat_interval
          self._callback = callback
          return true
        end

        function timer:stop()
          self._stop_calls = self._stop_calls + 1
          return true
        end

        function timer:close()
          self._close_calls = self._close_calls + 1
          return true
        end

        function timer:fire()
          assert(self._callback, "Timer has no callback; did you call :start()?")
          return self._callback()
        end

        return timer
      end,
    },

    test = { ---@type vim_test_utils
      set_mode = function(mode)
        _G.vim._current_mode = mode
      end,

      set_cursor = function(win, row, col)
        if not _G.vim._windows[win] then
          _G.vim._windows[win] = {}
        end
        _G.vim._windows[win].cursor = { row, col }
      end,

      add_buffer = function(bufnr, name, content)
        local lines = {}
        if type(content) == "string" then
          for line in content:gmatch("([^\n]*)\n?") do
            table.insert(lines, line)
          end
        elseif type(content) == "table" then
          lines = content
        end

        _G.vim._buffers[bufnr] = {
          name = name,
          lines = lines,
          options = {},
          listed = true,
        }
      end,
    },

    notify = function(_, _, _) end,
    log = {
      levels = {
        NONE = 0,
        ERROR = 1,
        WARN = 2,
        INFO = 3,
        DEBUG = 4,
        TRACE = 5,
      },
    },
    o = { ---@type vim_options_table
      columns = 80,
      lines = 24,
    }, -- Mock for vim.o
    bo = setmetatable({}, { -- Mock for vim.bo and vim.bo[bufnr]
      __index = function(t, k)
        if type(k) == "number" then
          if not t[k] then
            t[k] = {} -- Return a new table for vim.bo[bufnr]
          end
          return t[k]
        end
        return nil
      end,
    }),
    diagnostic = { -- Mock for vim.diagnostic
      get = function()
        return {}
      end,
      -- Add other vim.diagnostic functions if needed by tests
    },
    empty_dict = function()
      return {}
    end, -- Mock for vim.empty_dict()
    g = {}, -- Mock for vim.g
    v = { event = {} }, -- Mock for vim.v (ModeChanged supplies v:event.old_mode/new_mode)
    deepcopy = function(orig)
      local orig_type = type(orig)
      local copy
      if orig_type == "table" then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
          copy[_G.vim.deepcopy(orig_key)] = _G.vim.deepcopy(orig_value)
        end
        setmetatable(copy, _G.vim.deepcopy(getmetatable(orig)))
      else
        copy = orig
      end
      return copy
    end,
    tbl_deep_extend = function(behavior, ...)
      local tables = { ... }
      if #tables == 0 then
        return {}
      end
      local result = _G.vim.deepcopy(tables[1])

      for i = 2, #tables do
        local source = tables[i]
        if type(source) == "table" then
          for k, v in pairs(source) do
            if behavior == "force" then
              if type(v) == "table" and type(result[k]) == "table" then
                result[k] = _G.vim.tbl_deep_extend(behavior, result[k], v)
              else
                result[k] = _G.vim.deepcopy(v)
              end
            elseif behavior == "keep" then
              if result[k] == nil then
                result[k] = _G.vim.deepcopy(v)
              elseif type(v) == "table" and type(result[k]) == "table" then
                result[k] = _G.vim.tbl_deep_extend(behavior, result[k], v)
              end
              -- Add other behaviors like "error" if needed by tests
            end
          end
        end
      end
      return result
    end,
  }

  _G.vim.test.add_buffer(1, "/path/to/test.lua", "local test = {}\nreturn test")
  _G.vim.test.set_cursor(1, 1, 0)
end

-- luacheck: globals mock_server
describe("Selection module", function()
  local selection
  mock_server = {
    broadcast = function(event, data)
      -- Store last broadcast for testing
      mock_server.last_broadcast = {
        event = event,
        data = data,
      }
    end,
    last_broadcast = nil,
  }

  setup(function()
    package.loaded["claudecode.selection"] = nil

    selection = require("claudecode.selection")
  end)

  teardown(function()
    if selection.state.tracking_enabled then
      selection.disable()
    end
    mock_server.last_broadcast = nil
  end)

  it("should have the correct initial state", function()
    assert(type(selection.state) == "table")
    assert(selection.state.latest_selection == nil)
    assert(selection.state.tracking_enabled == false)
    assert(selection.state.debounce_timer == nil)
    assert(type(selection.state.debounce_ms) == "number")
  end)

  it("should enable and disable tracking", function()
    selection.enable(mock_server)

    assert(selection.state.tracking_enabled == true)
    assert(mock_server == selection.server)

    selection.disable()

    assert(selection.state.tracking_enabled == false)
    assert(selection.server == nil)
    assert(selection.state.latest_selection == nil)
  end)

  describe("debounce_update", function()
    it("should cancel and close previous debounce timer when re-debouncing", function()
      local update_calls = 0
      local old_update_selection = selection.update_selection

      selection.update_selection = function()
        update_calls = update_calls + 1
      end

      selection.debounce_update()
      local timer1 = selection.state.debounce_timer
      assert(timer1 ~= nil)

      selection.debounce_update()
      local timer2 = selection.state.debounce_timer
      assert(timer2 ~= nil)
      assert.are_not.equal(timer1, timer2)

      assert.are.equal(1, timer1._stop_calls)
      assert.are.equal(1, timer1._close_calls)

      -- Clean up the active timer
      timer2:fire()
      assert.are.equal(1, update_calls)

      selection.update_selection = old_update_selection
    end)

    it("should ignore stale debounce timer callbacks", function()
      local update_calls = 0
      local old_update_selection = selection.update_selection

      selection.update_selection = function()
        update_calls = update_calls + 1
      end

      selection.debounce_update()
      local timer1 = selection.state.debounce_timer
      assert(timer1 ~= nil)

      selection.debounce_update()
      local timer2 = selection.state.debounce_timer
      assert(timer2 ~= nil)

      -- A callback from a cancelled timer should be ignored.
      timer1:fire()
      assert.are.equal(0, update_calls)
      -- Stale callback must not double-stop or double-close the already-cancelled timer.
      assert.are.equal(1, timer1._stop_calls)
      assert.are.equal(1, timer1._close_calls)

      timer2:fire()
      assert.are.equal(1, update_calls)
      assert(selection.state.debounce_timer == nil)
      assert.are.equal(1, timer2._stop_calls)
      assert.are.equal(1, timer2._close_calls)

      selection.update_selection = old_update_selection
    end)

    it("disable() should cancel an active debounce timer", function()
      selection.enable(mock_server)
      selection.debounce_update()
      local timer = selection.state.debounce_timer
      assert(timer ~= nil)

      selection.disable()
      assert(selection.state.debounce_timer == nil)
      assert.are.equal(1, timer._stop_calls)
      assert.are.equal(1, timer._close_calls)
    end)
  end)

  describe("demotion_timer", function()
    local function install_terminal_stub()
      local terminal_module = package.loaded["claudecode.terminal"]
      local original_get = terminal_module and terminal_module.get_active_terminal_bufnr or nil
      if not terminal_module then
        terminal_module = {}
        package.loaded["claudecode.terminal"] = terminal_module
      end
      terminal_module.get_active_terminal_bufnr = function()
        return nil
      end
      return original_get, terminal_module
    end

    it("disable() should cancel an active demotion timer and ignore stale callbacks", function()
      local original_get, terminal_module = install_terminal_stub()

      selection.enable(mock_server)

      -- Seed a non-empty visual selection so the demotion path triggers on normal-mode entry.
      selection.state.last_active_visual_selection = {
        bufnr = 1,
        selection_data = {
          text = "x",
          filePath = "/path/to/test.lua",
          fileUrl = "file:///path/to/test.lua",
          selection = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 1 },
            isEmpty = false,
          },
        },
        timestamp = 0,
      }
      selection.state.latest_selection = selection.state.last_active_visual_selection.selection_data

      _G.vim.test.set_mode("n")
      selection.update_selection()

      local timer = selection.state.demotion_timer
      assert(timer ~= nil)

      selection.disable()

      assert(selection.state.demotion_timer == nil)
      assert(selection.state.latest_selection == nil)
      assert(selection.state.last_active_visual_selection == nil)
      assert.are.equal(1, timer._stop_calls)
      assert.are.equal(1, timer._close_calls)

      -- A late-firing callback from the cancelled timer must not mutate state after teardown.
      timer:fire()
      assert(selection.state.latest_selection == nil)
      assert(selection.state.demotion_timer == nil)
      assert(selection.state.last_active_visual_selection == nil)
      assert.are.equal(1, timer._stop_calls)
      assert.are.equal(1, timer._close_calls)

      terminal_module.get_active_terminal_bufnr = original_get
    end)

    it("should demote to cursor position when timer fires normally", function()
      local original_get, terminal_module = install_terminal_stub()

      selection.enable(mock_server)

      local visual_selection = {
        text = "x",
        filePath = "/path/to/test.lua",
        fileUrl = "file:///path/to/test.lua",
        selection = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 1 },
          isEmpty = false,
        },
      }
      selection.state.last_active_visual_selection = {
        bufnr = 1,
        selection_data = visual_selection,
        timestamp = 0,
      }
      selection.state.latest_selection = visual_selection

      _G.vim.test.set_mode("n")
      _G.vim.test.set_cursor(0, 2, 3)
      mock_server.last_broadcast = nil

      selection.update_selection()

      local timer = selection.state.demotion_timer
      assert(timer ~= nil)

      timer:fire()

      assert(selection.state.demotion_timer == nil)
      assert.are.equal(1, timer._stop_calls)
      assert.are.equal(1, timer._close_calls)

      local demoted = selection.state.latest_selection
      assert(demoted ~= nil)
      assert.are.equal("", demoted.text)
      assert.are.equal(true, demoted.selection.isEmpty)
      assert.are.equal(1, demoted.selection.start.line)
      assert.are.equal(3, demoted.selection.start.character)
      assert(selection.state.last_active_visual_selection == nil)
      assert(mock_server.last_broadcast ~= nil)
      assert.are.equal("selection_changed", mock_server.last_broadcast.event)

      selection.disable()
      terminal_module.get_active_terminal_bufnr = original_get
    end)
  end)

  it("should get cursor position in normal mode", function()
    local old_win_get_cursor = _G.vim.api.nvim_win_get_cursor
    _G.vim.api.nvim_win_get_cursor = function()
      return { 2, 3 } -- row 2, col 3 (1-based)
    end

    _G.vim.test.set_mode("n")

    local cursor_pos = selection.get_cursor_position()

    _G.vim.api.nvim_win_get_cursor = old_win_get_cursor

    assert(type(cursor_pos) == "table")
    assert("" == cursor_pos.text)
    assert(type(cursor_pos.filePath) == "string")
    assert(type(cursor_pos.fileUrl) == "string")
    assert(type(cursor_pos.selection) == "table")
    assert(type(cursor_pos.selection.start) == "table")
    assert(type(cursor_pos.selection["end"]) == "table")

    -- Check positions - 0-based in selection, source is 1-based from nvim_win_get_cursor
    assert(1 == cursor_pos.selection.start.line) -- Should be 2-1=1
    assert(3 == cursor_pos.selection.start.character)
    assert(1 == cursor_pos.selection["end"].line)
    assert(3 == cursor_pos.selection["end"].character)
    assert(cursor_pos.selection.isEmpty == true)
  end)

  it("should detect selection changes", function()
    local old_selection = {
      text = "test",
      filePath = "/path/file1.lua",
      fileUrl = "file:///path/file1.lua",
      selection = {
        start = { line = 1, character = 0 },
        ["end"] = { line = 1, character = 4 },
        isEmpty = false,
      },
    }

    local new_selection_same = {
      text = "test",
      filePath = "/path/file1.lua",
      fileUrl = "file:///path/file1.lua",
      selection = {
        start = { line = 1, character = 0 },
        ["end"] = { line = 1, character = 4 },
        isEmpty = false,
      },
    }

    local new_selection_diff_file = {
      text = "test",
      filePath = "/path/file2.lua",
      fileUrl = "file:///path/file2.lua",
      selection = {
        start = { line = 1, character = 0 },
        ["end"] = { line = 1, character = 4 },
        isEmpty = false,
      },
    }

    local new_selection_diff_text = {
      text = "test2",
      filePath = "/path/file1.lua",
      fileUrl = "file:///path/file1.lua",
      selection = {
        start = { line = 1, character = 0 },
        ["end"] = { line = 1, character = 5 },
        isEmpty = false,
      },
    }

    local new_selection_diff_pos = {
      text = "test",
      filePath = "/path/file1.lua",
      fileUrl = "file:///path/file1.lua",
      selection = {
        start = { line = 2, character = 0 },
        ["end"] = { line = 2, character = 4 },
        isEmpty = false,
      },
    }

    selection.state.latest_selection = old_selection

    assert(selection.has_selection_changed(new_selection_same) == false)

    assert(selection.has_selection_changed(new_selection_diff_file) == true)

    assert(selection.has_selection_changed(new_selection_diff_text) == true)

    assert(selection.has_selection_changed(new_selection_diff_pos) == true)
  end)
end)

-- Tests for range selection functionality (fix for issue #25)
describe("Range Selection Tests", function()
  local selection

  before_each(function()
    -- Reset vim state
    _G.vim._buffers = {
      [1] = {
        name = "/test/file.lua",
        lines = {
          "line 1",
          "line 2",
          "line 3",
          "line 4",
          "line 5",
          "line 6",
          "line 7",
          "line 8",
          "line 9",
          "line 10",
        },
      },
    }
    _G.vim._windows = {
      [1] = {
        cursor = { 1, 0 },
      },
    }
    _G.vim._current_mode = "n"

    -- Add nvim_buf_line_count function
    _G.vim.api.nvim_buf_line_count = function(bufnr)
      return _G.vim._buffers[bufnr] and #_G.vim._buffers[bufnr].lines or 0
    end

    -- Reload the selection module
    package.loaded["claudecode.selection"] = nil
    selection = require("claudecode.selection")
  end)

  describe("get_range_selection", function()
    it("should return valid selection for valid range", function()
      local result = selection.get_range_selection(2, 4)

      assert(result ~= nil)
      assert(result.text == "line 2\nline 3\nline 4")
      assert(result.filePath == "/test/file.lua")
      assert(result.fileUrl == "file:///test/file.lua")
      assert(result.selection.start.line == 1) -- 0-indexed
      assert(result.selection.start.character == 0)
      assert(result.selection["end"].line == 3) -- 0-indexed
      assert(result.selection["end"].character == 6) -- length of "line 4"
      assert(result.selection.isEmpty == false)
    end)

    it("should return valid selection for single line range", function()
      local result = selection.get_range_selection(3, 3)

      assert(result ~= nil)
      assert(result.text == "line 3")
      assert(result.selection.start.line == 2) -- 0-indexed
      assert(result.selection["end"].line == 2) -- 0-indexed
      assert(result.selection.isEmpty == false)
    end)

    it("should handle range that exceeds buffer bounds", function()
      local result = selection.get_range_selection(8, 15) -- buffer only has 10 lines

      assert(result ~= nil)
      assert(result.text == "line 8\nline 9\nline 10")
      assert(result.selection.start.line == 7) -- 0-indexed
      assert(result.selection["end"].line == 9) -- 0-indexed, clamped to buffer size
    end)

    it("should return nil for invalid range (line1 > line2)", function()
      local result = selection.get_range_selection(5, 3)
      assert(result == nil)
    end)

    it("should return nil for invalid range (line1 < 1)", function()
      local result = selection.get_range_selection(0, 3)
      assert(result == nil)
    end)

    it("should return nil for invalid range (line2 < 1)", function()
      local result = selection.get_range_selection(2, 0)
      assert(result == nil)
    end)

    it("should return nil for nil parameters", function()
      local result1 = selection.get_range_selection(nil, 3)
      local result2 = selection.get_range_selection(2, nil)
      local result3 = selection.get_range_selection(nil, nil)

      assert(result1 == nil)
      assert(result2 == nil)
      assert(result3 == nil)
    end)

    it("should handle empty buffer", function()
      _G.vim._buffers[1].lines = {}
      local result = selection.get_range_selection(1, 1)
      assert(result == nil)
    end)
  end)

  describe("send_at_mention_for_visual_selection with range", function()
    local mock_server
    local mock_claudecode_main
    local original_require

    before_each(function()
      mock_server = {
        broadcast = function(event, params)
          mock_server.last_broadcast = {
            event = event,
            params = params,
          }
          return true
        end,
      }

      mock_claudecode_main = {
        state = {
          server = mock_server,
        },
        send_at_mention = function(file_path, start_line, end_line, context)
          -- Convert to the format expected by tests (1-indexed to 0-indexed conversion done here)
          local params = {
            filePath = file_path,
            lineStart = start_line,
            lineEnd = end_line,
          }
          return mock_server.broadcast("at_mentioned", params), nil
        end,
      }

      -- Mock the require function to return our mock claudecode module
      original_require = _G.require
      _G.require = function(module_name)
        if module_name == "claudecode" then
          return mock_claudecode_main
        else
          return original_require(module_name)
        end
      end

      selection.state.tracking_enabled = true
      selection.server = mock_server
    end)

    after_each(function()
      _G.require = original_require
    end)

    it("should send range selection successfully", function()
      local result = selection.send_at_mention_for_visual_selection(2, 4)

      assert(result == true)
      assert(mock_server.last_broadcast ~= nil)
      assert(mock_server.last_broadcast.event == "at_mentioned")
      assert(mock_server.last_broadcast.params.filePath == "/test/file.lua")
      assert(mock_server.last_broadcast.params.lineStart == 1) -- 0-indexed
      assert(mock_server.last_broadcast.params.lineEnd == 3) -- 0-indexed
    end)

    it("should fail for invalid range", function()
      local result = selection.send_at_mention_for_visual_selection(5, 3)
      assert(result == false)
    end)

    it("should fall back to existing logic when no range provided", function()
      -- Set up a tracked selection
      selection.state.latest_selection = {
        text = "tracked text",
        filePath = "/test/file.lua",
        fileUrl = "file:///test/file.lua",
        selection = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 0, character = 12 },
          isEmpty = false,
        },
      }

      local result = selection.send_at_mention_for_visual_selection()

      assert(result == true)
      assert(mock_server.last_broadcast.params.lineStart == 0)
      assert(mock_server.last_broadcast.params.lineEnd == 0)
    end)

    it("should fail when server is not available", function()
      mock_claudecode_main.state.server = nil
      local result = selection.send_at_mention_for_visual_selection(2, 4)
      assert(result == false)
    end)

    it("should fail when tracking is disabled", function()
      selection.state.tracking_enabled = false
      local result = selection.send_at_mention_for_visual_selection(2, 4)
      assert(result == false)
    end)
  end)

  describe("issue #246 - flush on visual exit + cursor-guarded demotion", function()
    local terminal_module = require("claudecode.terminal")
    local original_get_term
    -- Own mock_server (declared local-first so the broadcast closure captures THIS table).
    -- `selection` reuses the enclosing describe's upvalue, refreshed per-test in before_each.
    local mock_server = {}
    mock_server.broadcast = function(event, data)
      mock_server.last_broadcast = { event = event, data = data }
    end

    before_each(function()
      package.loaded["claudecode.selection"] = nil
      selection = require("claudecode.selection")
      original_get_term = terminal_module.get_active_terminal_bufnr
      terminal_module.get_active_terminal_bufnr = function()
        return nil -- external Claude: no in-Neovim terminal buffer
      end
      mock_server.last_broadcast = nil
      _G.vim.v.event = {}
    end)

    after_each(function()
      if selection.state.tracking_enabled then
        selection.disable()
      end
      terminal_module.get_active_terminal_bufnr = original_get_term
      _G.vim._marks = nil
      _G.vim._visualmode = nil
      _G.vim._changedtick = nil
      _G.vim.v.event = {}
      -- Restore the default shared buffer so later specs are unaffected.
      _G.vim.test.add_buffer(1, "/path/to/test.lua", "local test = {}\nreturn test")
      _G.vim.test.set_cursor(1, 1, 0)
    end)

    describe("get_visual_selection_from_marks()", function()
      it("extracts a single-line charwise selection from the '<,'> marks", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta gamma" })
        _G.vim._visualmode = "v"
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 1, 5, 0 } }

        local sel = selection.get_visual_selection_from_marks()

        assert(sel ~= nil)
        assert.are.equal("alpha", sel.text)
        assert.are.equal(false, sel.selection.isEmpty)
        assert.are.equal(0, sel.selection.start.line)
        assert.are.equal(0, sel.selection.start.character)
        assert.are.equal(0, sel.selection["end"].line)
        assert.are.equal(5, sel.selection["end"].character)
      end)

      it("extracts a single-line linewise V selection (whole line), clamping MAXCOL '>", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta gamma", "delta epsilon zeta" })
        _G.vim._visualmode = "V"
        _G.vim._marks = { ["'<"] = { 0, 2, 1, 0 }, ["'>"] = { 0, 2, 2147483647, 0 } }

        local sel = selection.get_visual_selection_from_marks()

        assert(sel ~= nil)
        assert.are.equal("delta epsilon zeta", sel.text)
        assert.are.equal(false, sel.selection.isEmpty)
        assert.are.equal(1, sel.selection.start.line)
        assert.are.equal(0, sel.selection.start.character)
        assert.are.equal(1, sel.selection["end"].line)
        assert.are.equal(#"delta epsilon zeta", sel.selection["end"].character)
      end)

      it("returns nil when no visual selection was ever recorded", function()
        _G.vim._visualmode = ""
        assert(selection.get_visual_selection_from_marks() == nil)
      end)

      it("reports an empty-line linewise selection as isEmpty", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "" })
        _G.vim._visualmode = "V"
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 1, 2147483647, 0 } }

        local sel = selection.get_visual_selection_from_marks()

        assert(sel ~= nil)
        assert.are.equal("", sel.text)
        assert.are.equal(true, sel.selection.isEmpty)
      end)

      it("approximates a blockwise selection as the contiguous charwise span (documented limitation)", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta", "gamma delta" })
        _G.vim._visualmode = "\22" -- CTRL-V blockwise
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 2, 2, 0 } } -- cols 1-2 across 2 lines

        local sel = selection.get_visual_selection_from_marks()

        assert(sel ~= nil)
        -- Charwise approximation, NOT the rectangular block "al"/"ga": selection_changed
        -- carries a single range, so the block is sent as its contiguous span.
        assert.are.equal("alpha beta\nga", sel.text)
        assert.are.equal(false, sel.selection.isEmpty)
      end)
    end)

    describe("on_mode_changed() flush", function()
      it("broadcasts a fast single-line selection on visual->normal exit", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta gamma" })
        selection.enable(mock_server)
        _G.vim.test.set_mode("n") -- nvim_get_mode already reports normal at this point
        _G.vim.test.set_cursor(0, 1, 4)
        _G.vim._visualmode = "v"
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 1, 5, 0 } }
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }
        mock_server.last_broadcast = nil

        selection.on_mode_changed()

        assert(mock_server.last_broadcast ~= nil)
        assert.are.equal("selection_changed", mock_server.last_broadcast.event)
        assert.are.equal("alpha", mock_server.last_broadcast.data.text)
        assert.are.equal(false, mock_server.last_broadcast.data.selection.isEmpty)
        assert(selection.state.latest_selection ~= nil)
        assert.are.equal("alpha", selection.state.latest_selection.text)
        assert(selection.state.cursor_at_flush ~= nil)
      end)

      it("does NOT flush on a visual->visual transition (v to V)", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta gamma" })
        selection.enable(mock_server)
        _G.vim._visualmode = "v"
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 1, 5, 0 } }
        _G.vim.v.event = { old_mode = "v", new_mode = "V" }
        mock_server.last_broadcast = nil

        selection.on_mode_changed()

        assert(mock_server.last_broadcast == nil)
      end)

      it("does NOT flush a phantom selection when an operator mutated the buffer (viwd)", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta gamma" })
        selection.enable(mock_server)
        _G.vim._visualmode = "v"
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 1, 5, 0 } }

        -- Enter visual mode: records the entry changedtick.
        _G.vim._changedtick = 7
        _G.vim.v.event = { old_mode = "n", new_mode = "v" }
        selection.on_mode_changed()

        -- An operator (d) mutates the buffer (tick advances) and exits visual mode.
        _G.vim._changedtick = 8
        _G.vim.test.set_mode("n")
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }
        mock_server.last_broadcast = nil

        selection.on_mode_changed()

        assert(mock_server.last_broadcast == nil) -- no phantom post-edit broadcast
        assert(selection.state.latest_selection == nil)
      end)

      it("does not double-send a selection already broadcast by the in-visual debounce", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta gamma" })
        selection.enable(mock_server)
        _G.vim._visualmode = "v"
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 1, 5, 0 } }
        -- The in-visual debounce already sent this exact selection.
        selection.state.latest_selection = selection.get_visual_selection_from_marks()
        _G.vim.test.set_mode("n")
        _G.vim.test.set_cursor(0, 1, 4)
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }
        mock_server.last_broadcast = nil

        selection.on_mode_changed()

        assert(mock_server.last_broadcast == nil) -- dedup: no resend on exit
      end)

      it("does not flush when the active buffer is the Claude terminal", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta gamma" })
        selection.enable(mock_server)
        terminal_module.get_active_terminal_bufnr = function()
          return 1 -- the current buffer IS the Claude terminal
        end
        _G.vim._visualmode = "v"
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 1, 5, 0 } }
        _G.vim.test.set_mode("n")
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }
        mock_server.last_broadcast = nil

        selection.on_mode_changed()

        assert(mock_server.last_broadcast == nil)
      end)
    end)

    describe("cursor-guarded demotion", function()
      local function seed_held_selection()
        local visual_selection = {
          text = "alpha",
          filePath = "/path/to/test.lua",
          fileUrl = "file:///path/to/test.lua",
          selection = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 5 },
            isEmpty = false,
          },
        }
        selection.state.last_active_visual_selection = { bufnr = 1, selection_data = visual_selection, timestamp = 0 }
        selection.state.latest_selection = visual_selection
        selection.state.cursor_at_flush = { bufnr = 1, pos = { 1, 4 } }
      end

      it("keeps a held selection when the cursor has not moved since the flush", function()
        selection.enable(mock_server)
        seed_held_selection()
        _G.vim.test.set_mode("n")
        _G.vim.test.set_cursor(0, 1, 4) -- identical to cursor_at_flush -> unmoved
        mock_server.last_broadcast = nil

        selection.update_selection()
        local timer = selection.state.demotion_timer
        assert(timer ~= nil)
        timer:fire()

        assert.are.equal("alpha", selection.state.latest_selection.text)
        assert.are.equal(false, selection.state.latest_selection.selection.isEmpty)
        assert(mock_server.last_broadcast == nil)
        -- kept intact so a later real cursor move can still re-arm demotion
        assert(selection.state.last_active_visual_selection ~= nil)
      end)

      it("demotes to an empty cursor once the cursor has moved since the flush", function()
        selection.enable(mock_server)
        seed_held_selection()
        _G.vim.test.set_mode("n")
        _G.vim.test.set_cursor(0, 1, 6) -- moved from {1,4}
        mock_server.last_broadcast = nil

        selection.update_selection()
        local timer = selection.state.demotion_timer
        assert(timer ~= nil)
        timer:fire()

        assert.are.equal("", selection.state.latest_selection.text)
        assert.are.equal(true, selection.state.latest_selection.selection.isEmpty)
        assert(mock_server.last_broadcast ~= nil)
        assert.are.equal("selection_changed", mock_server.last_broadcast.event)
      end)

      it("still demotes when no flush occurred (cursor_at_flush nil = legacy path)", function()
        selection.enable(mock_server)
        seed_held_selection()
        selection.state.cursor_at_flush = nil -- e.g. selection captured by the in-visual debounce only
        _G.vim.test.set_mode("n")
        _G.vim.test.set_cursor(0, 2, 3)
        mock_server.last_broadcast = nil

        selection.update_selection()
        local timer = selection.state.demotion_timer
        assert(timer ~= nil)
        timer:fire()

        assert.are.equal(true, selection.state.latest_selection.selection.isEmpty)
        assert(mock_server.last_broadcast ~= nil)
      end)

      it("does not wipe a held selection on a pending-demotion re-entry while unmoved", function()
        selection.enable(mock_server)
        seed_held_selection() -- cursor_at_flush = { bufnr = 1, pos = { 1, 4 } }
        _G.vim.test.set_mode("n")
        _G.vim.test.set_cursor(0, 1, 4) -- unmoved

        selection.update_selection() -- arms the demotion timer
        assert(selection.state.demotion_timer ~= nil)
        mock_server.last_broadcast = nil

        -- A second update runs while demotion is still pending and the cursor has not moved
        -- (reachable when visual_demotion_delay_ms >= debounce_ms). It must NOT wipe the selection.
        selection.update_selection()

        assert.are.equal("alpha", selection.state.latest_selection.text)
        assert.are.equal(false, selection.state.latest_selection.selection.isEmpty)
        assert(mock_server.last_broadcast == nil)
      end)

      it("clears a held selection's tracked state when normal mode is entered in another buffer", function()
        selection.enable(mock_server)
        -- A held selection that belongs to a DIFFERENT buffer (2); current buffer is 1.
        seed_held_selection()
        selection.state.last_active_visual_selection.bufnr = 2
        selection.state.cursor_at_flush = { bufnr = 2, pos = { 1, 4 } }
        _G.vim.test.set_mode("n")
        _G.vim.test.set_cursor(0, 1, 0)

        selection.update_selection() -- else branch: different buffer, no demotion pending

        -- Stale cross-buffer state must not leak (no demotion timer armed for the other buffer).
        assert(selection.state.last_active_visual_selection == nil)
        assert(selection.state.cursor_at_flush == nil)
        assert(selection.state.demotion_timer == nil)
      end)
    end)
  end)
end)
