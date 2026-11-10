-- Like Neovim, a byte that does not start a complete UTF-8 sequence is a character of its own.
local function mock_code_point(line, i)
  local b = line:byte(i)
  if not b then
    return nil, 0
  end
  if b < 0xC0 or b >= 0xF8 then
    return b, 1
  end
  local len = b < 0xE0 and 2 or b < 0xF0 and 3 or 4
  local cp = b - (len == 2 and 0xC0 or len == 3 and 0xE0 or 0xF0)
  for j = i + 1, i + len - 1 do
    local next_byte = line:byte(j)
    if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then
      return b, 1
    end
    cp = cp * 64 + (next_byte - 0x80)
  end
  return cp, len
end

-- A few code points that Neovim 0.11+ counts as a character of their own (Grapheme_Cluster_Break=Control): C0 and
-- C1 controls, DEL, SOFT HYPHEN, ZERO WIDTH SPACE, LINE and PARAGRAPH SEPARATOR, and ZERO WIDTH NO-BREAK SPACE.
local function mock_is_grapheme_control(cp)
  return cp < 0x20
    or (cp >= 0x7F and cp <= 0x9F)
    or cp == 0xAD
    or cp == 0x200B
    or cp == 0x2028
    or cp == 0x2029
    or cp == 0xFEFF
end

-- Last byte of the character that starts at byte i. A character is a code point and its composing characters
-- (here U+0300 to U+036F and the Devanagari signs U+093A to U+094F). As on Neovim 0.11 and later, a virama also
-- joins the next consonant, so स्ते is one character from स, while the cursor can still stand on त.
-- With own_controls, a control (see mock_is_grapheme_control) is a character of its own, as Neovim 0.11+ counts
-- characters for the cursor and `y`.
local function mock_char_last_byte(line, i, own_controls)
  local last_cp, len = mock_code_point(line, i)
  local stop = i + len
  if own_controls and last_cp and mock_is_grapheme_control(last_cp) then
    return stop - 1
  end
  while true do
    local cp, next_len = mock_code_point(line, stop)
    local composing = cp and ((cp >= 0x300 and cp <= 0x36F) or (cp >= 0x93A and cp <= 0x94F))
    local conjunct = cp and last_cp == 0x94D and cp >= 0x915 and cp <= 0x939
    if not (composing or conjunct) then
      return stop - 1
    end
    last_cp, stop = cp, stop + next_len
  end
end

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
    _buf_listeners = {}, -- nvim_buf_attach: bufnr -> { callbacks }
    _buffer_windows = {}, -- vim.fn.win_findbuf: bufnr -> { winid }
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

      nvim_buf_is_valid = function(bufnr)
        return _G.vim._buffers[bufnr] ~= nil
      end,

      nvim_buf_is_loaded = function(bufnr)
        return _G.vim._buffers[bufnr] ~= nil
      end,

      nvim_buf_attach = function(bufnr, _send_buffer, callbacks)
        _G.vim._buf_listeners[bufnr] = _G.vim._buf_listeners[bufnr] or {}
        table.insert(_G.vim._buf_listeners[bufnr], callbacks)
        return true
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

      nvim_buf_line_count = function(bufnr)
        return _G.vim._buffers[bufnr] and #_G.vim._buffers[bufnr].lines or 0
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
      -- byteidx and charidx count characters the way `y` does, so on Neovim 0.11+ (tests set
      -- _G.vim._has["nvim-0.11"]) a control is a character of its own.
      byteidx = function(str, nr)
        assert(not str:find("%z"), "Vim:E976: Using a Blob as a String")
        local own_controls = _G.vim._has and _G.vim._has["nvim-0.11"]
        local i = 1
        for _ = 1, nr do
          if i > #str then
            return -1
          end
          i = mock_char_last_byte(str, i, own_controls) + 1
        end
        return i - 1
      end,
      charidx = function(str, idx)
        assert(not str:find("%z"), "Vim:E976: Using a Blob as a String")
        local own_controls = _G.vim._has and _G.vim._has["nvim-0.11"]
        local i, index = 1, 0
        while i <= #str do
          local last = mock_char_last_byte(str, i, own_controls)
          if idx + 1 <= last then
            return index
          end
          i, index = last + 1, index + 1
        end
        return -1
      end,
      win_findbuf = function(bufnr)
        return _G.vim._buffer_windows[bufnr] or {}
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
      virtualedit = "",
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

  -- A fresh module per test: the state checks below must not see what an earlier test left.
  before_each(function()
    package.loaded["claudecode.selection"] = nil

    selection = require("claudecode.selection")
  end)

  after_each(function()
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

  it("should read the cursor and buffer of the given window", function()
    _G.vim.test.add_buffer(42, "/other/window.lua", { "one", "two", "three" })
    local old_get_cursor, old_get_buf = _G.vim.api.nvim_win_get_cursor, _G.vim.api.nvim_win_get_buf
    finally(function()
      _G.vim.api.nvim_win_get_cursor, _G.vim.api.nvim_win_get_buf = old_get_cursor, old_get_buf
    end)
    _G.vim.api.nvim_win_get_cursor = function(winid)
      assert(winid == 1042, "read the cursor of window " .. tostring(winid))
      return { 3, 2 }
    end
    _G.vim.api.nvim_win_get_buf = function(winid)
      assert(winid == 1042, "read the buffer of window " .. tostring(winid))
      return 42
    end

    local cursor_pos = selection.get_cursor_position(1042)

    assert(cursor_pos.filePath == "/other/window.lua", "got " .. tostring(cursor_pos.filePath))
    assert(cursor_pos.selection.start.line == 2)
    assert(cursor_pos.selection.start.character == 2)
    assert(cursor_pos.selection.isEmpty == true)
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

    it("keeps an explicit range's last line when that line is empty", function()
      _G.vim._buffers[1].lines[3] = ""

      assert.is_true(selection.send_at_mention_for_visual_selection(2, 3))

      assert.are.equal(1, mock_server.last_broadcast.params.lineStart)
      assert.are.equal(2, mock_server.last_broadcast.params.lineEnd)
    end)

    it("ends the mention on the line before when the tracked selection ends at character 0 of a line", function()
      -- `v$` on line 0 includes its line break and ends at the start of line 1.
      selection.state.latest_selection = {
        text = "abc\n",
        filePath = "/test/file.lua",
        fileUrl = "file:///test/file.lua",
        selection = {
          start = { line = 0, character = 0 },
          ["end"] = { line = 1, character = 0 },
          isEmpty = false,
        },
      }

      assert.is_true(selection.send_at_mention_for_visual_selection())

      assert.are.equal(0, mock_server.last_broadcast.params.lineStart)
      assert.are.equal(0, mock_server.last_broadcast.params.lineEnd)
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

    describe("multibyte characters (#362)", function()
      local function is_valid_utf8(text)
        local i = 1
        while i <= #text do
          local lead = text:byte(i)
          local len = lead < 0x80 and 1
            or lead >= 0xC2 and lead < 0xE0 and 2
            or lead >= 0xE0 and lead < 0xF0 and 3
            or lead >= 0xF0 and lead < 0xF5 and 4
          if not len then
            return false
          end
          for j = i + 1, i + len - 1 do
            local byte = text:byte(j)
            if not byte or byte < 0x80 or byte >= 0xC0 then
              return false
            end
          end
          i = i + len
        end
        return true
      end

      local function from_marks(lines, mode, start_lnum, start_col, end_lnum, end_col)
        _G.vim.test.add_buffer(1, "/path/to/test.lua", lines)
        _G.vim._visualmode = mode
        _G.vim._marks = { ["'<"] = { 0, start_lnum, start_col, 0 }, ["'>"] = { 0, end_lnum, end_col, 0 } }
        local sel = selection.get_visual_selection_from_marks()
        assert(sel ~= nil)
        assert.is_true(is_valid_utf8(sel.text))
        return sel
      end

      it("sends the whole last character when a live charwise selection ends on a multibyte one", function()
        -- The issue's repro: on the line `naïve café`, `0vwe` leaves the cursor on the final é (bytes 11-12).
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "line one", "cafe", "naïve café" })
        selection.enable(mock_server)
        _G.vim.test.set_mode("v")
        _G.vim._marks = { v = { 0, 3, 1, 0 } }
        _G.vim.test.set_cursor(0, 3, 10)

        selection.update_selection()

        local sent = mock_server.last_broadcast.data
        assert.is_true(is_valid_utf8(sent.text))
        assert.are.equal("naïve café", sent.text)
        assert.are.same({ line = 2, character = 0 }, sent.selection.start)
        assert.are.same({ line = 2, character = #"naïve café" }, sent.selection["end"])
      end)

      it("sends the whole last character on the visual-exit flush", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "naïve café" })
        selection.enable(mock_server)
        _G.vim.test.set_mode("n")
        _G.vim.test.set_cursor(0, 1, 10)
        _G.vim._visualmode = "v"
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 1, 11, 0 } }
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }

        selection.on_mode_changed()

        local sent = mock_server.last_broadcast.data
        assert.is_true(is_valid_utf8(sent.text))
        assert.are.equal("naïve café", sent.text)
        assert.are.equal(#"naïve café", sent.selection["end"].character)
      end)

      it("keeps a multi-line charwise selection whole when it starts and ends on multibyte characters", function()
        -- From the é of `café` (bytes 11-12) to the 本 of `日本語` (bytes 4-6).
        local sel = from_marks({ "naïve café", "日本語 テキスト" }, "v", 1, 11, 2, 4)
        assert.are.equal("é\n日本", sel.text)
        assert.are.equal(10, sel.selection.start.character)
        assert.are.equal(#"日本", sel.selection["end"].character)
      end)

      it("includes the composing characters of the last character", function()
        -- `e` followed by U+0301 COMBINING ACUTE ACCENT is one character in Neovim.
        local sel = from_marks({ "cafe\204\129 x" }, "v", 1, 1, 1, 4)
        assert.are.equal("cafe\204\129", sel.text)
        assert.are.equal(6, sel.selection["end"].character)
      end)

      it("keeps a selection whole when it ends inside a cluster, on a conjunct's inner consonant", function()
        -- `0ve` on `नमस्ते` ends on त (bytes 13-15). From the line start, स्ते (bytes 7-18) is one cluster.
        local sel = from_marks({ "नमस्ते" }, "v", 1, 1, 1, 13)
        assert.are.equal("नमस्ते", sel.text)
        assert.are.equal(#"नमस्ते", sel.selection["end"].character)
      end)

      it("sends the rest of the cluster for a live one-position selection on a conjunct's inner consonant", function()
        -- `$v` on `नमस्ते` puts the anchor and the cursor on त. Neovim then selects and yanks ते.
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "नमस्ते" })
        selection.enable(mock_server)
        _G.vim.test.set_mode("v")
        _G.vim._marks = { v = { 0, 1, 13, 0 } }
        _G.vim.test.set_cursor(0, 1, 12)

        selection.update_selection()

        local sent = mock_server.last_broadcast.data
        assert.is_true(is_valid_utf8(sent.text))
        assert.are.equal("ते", sent.text)
        assert.are.same({ line = 0, character = 12 }, sent.selection.start)
        assert.are.same({ line = 0, character = #"नमस्ते" }, sent.selection["end"])
      end)

      it("ends a selection on a 4-byte emoji after the emoji", function()
        local sel = from_marks({ "a😀b" }, "v", 1, 1, 1, 2)
        assert.are.equal("a😀", sel.text)
        assert.are.equal(5, sel.selection["end"].character)
      end)

      it("handles a line with a NUL byte", function()
        -- nvim_buf_get_lines returns NUL as "\0".
        local sel = from_marks({ "a\0b" }, "v", 1, 1, 1, 2)
        assert.are.equal("a\0", sel.text)
        assert.are.equal(2, sel.selection["end"].character)
      end)

      describe("when a stale position falls inside a character", function()
        -- Marks keep their byte column when text is inserted before them on the line. Select `cd` on `abcdef`,
        -- then insert `aé` at the line start: '< (column 3) is now the second byte of é.
        it("starts at the first byte of the character, from the marks", function()
          local sel = from_marks({ "aéabcdef" }, "v", 1, 3, 1, 4)
          assert.are.equal("éa", sel.text)
          assert.are.same({ line = 0, character = 1 }, sel.selection.start)
          assert.are.same({ line = 0, character = 4 }, sel.selection["end"])
        end)

        it("starts at the first byte of the character for a live selection after gv", function()
          _G.vim.test.add_buffer(1, "/path/to/test.lua", { "aéabcdef" })
          selection.enable(mock_server)
          _G.vim.test.set_mode("v")
          _G.vim._marks = { v = { 0, 1, 3, 0 } }
          _G.vim.test.set_cursor(0, 1, 3)

          selection.update_selection()

          local sent = mock_server.last_broadcast.data
          assert.is_true(is_valid_utf8(sent.text))
          assert.are.equal("éa", sent.text)
          assert.are.same({ line = 0, character = 1 }, sent.selection.start)
        end)

        it("ends after the whole character", function()
          -- Select `abc` backward, so the anchor is the c (column 3), then insert `x日`: column 3 is inside 日.
          local sel = from_marks({ "x日abcdef" }, "v", 1, 1, 1, 3)
          assert.are.equal("x日", sel.text)
          assert.are.same({ line = 0, character = #"x日" }, sel.selection["end"])
        end)
      end)

      describe("on a line that is not valid UTF-8", function()
        local replacement = "\239\191\189" -- U+FFFD REPLACEMENT CHARACTER

        it("sends U+FFFD for an invalid byte and keeps the buffer's byte columns", function()
          -- `:e ++bad=keep` keeps the byte 255 of a file that is not valid UTF-8.
          _G.vim.test.add_buffer(1, "/path/to/test.lua", { "abc\255def" })
          selection.enable(mock_server)
          _G.vim.test.set_mode("v")
          _G.vim._marks = { v = { 0, 1, 1, 0 } }
          _G.vim.test.set_cursor(0, 1, 6)

          selection.update_selection()

          local sent = mock_server.last_broadcast.data
          assert.are.equal("abc" .. replacement .. "def", sent.text)
          assert.are.same({ line = 0, character = 0 }, sent.selection.start)
          assert.are.same({ line = 0, character = 7 }, sent.selection["end"])
          assert.are.equal(sent.text, selection.get_latest_selection().text)
        end)

        it("keeps a position on a lone continuation byte, which Neovim treats as a character of its own", function()
          local sel = from_marks({ "a\128b" }, "v", 1, 2, 1, 2)
          assert.are.equal(replacement, sel.text)
          assert.are.same({ line = 0, character = 1 }, sel.selection.start)
          assert.are.same({ line = 0, character = 2 }, sel.selection["end"])
        end)

        it("sends one U+FFFD for each invalid sequence, as a UTF-8 decoder does", function()
          -- 日 cut after two bytes, a lone continuation byte, an overlong `/`, and an encoded surrogate half.
          local sel = from_marks({ "é\230\151b\128", "\192\175\237\160\128" }, "V", 1, 1, 2, 2147483647)
          assert.are.equal("é" .. replacement .. "b" .. replacement .. "\n" .. string.rep(replacement, 5), sel.text)
        end)
      end)

      it("keeps the contiguous span of a blockwise selection on character boundaries", function()
        local sel = from_marks({ "naïve café", "日本語 テキスト" }, "\22", 1, 1, 2, 4)
        assert.are.equal("naïve café\n日本", sel.text)
      end)

      describe("with 'selection' set to exclusive", function()
        before_each(function()
          _G.vim.o.selection = "exclusive"
        end)

        after_each(function()
          _G.vim.o.selection = nil
        end)

        it("leaves out the multibyte character at the end of a backward live selection", function()
          -- `$vb` on `naïve café`: the anchor stays on é (byte 11), and the cursor moves to the c (byte 8).
          _G.vim.test.add_buffer(1, "/path/to/test.lua", { "naïve café" })
          selection.enable(mock_server)
          _G.vim.test.set_mode("v")
          _G.vim._marks = { v = { 0, 1, 11, 0 } }
          _G.vim.test.set_cursor(0, 1, 7)

          selection.update_selection()

          local sent = mock_server.last_broadcast.data
          assert.are.equal("caf", sent.text)
          assert.are.same({ line = 0, character = 7 }, sent.selection.start)
          assert.are.same({ line = 0, character = 10 }, sent.selection["end"])
        end)

        it("leaves out the multibyte character at the '> mark of a multi-line selection", function()
          local sel = from_marks({ "naïve café", "日本語 テキスト" }, "v", 1, 11, 2, 4)
          assert.are.equal("é\n日", sel.text)
          assert.are.equal(#"日", sel.selection["end"].character)
        end)

        it("ends after the whole cluster before the end position, as Neovim 0.11+ does for a conjunct", function()
          -- `$v0` on `नमस्ते`: the excluded end position is त, and the character before it is the cluster स्ते,
          -- which reaches past त. Neovim 0.12 then yanks the whole word.
          local sel = from_marks({ "नमस्ते" }, "v", 1, 1, 1, 13)
          assert.are.equal("नमस्ते", sel.text)
          assert.are.equal(#"नमस्ते", sel.selection["end"].character)
        end)

        it("keeps the one character of a selection that starts and ends at the same position", function()
          local sel = from_marks({ "日本語" }, "v", 1, 1, 1, 1)
          assert.are.equal("日", sel.text)
          assert.are.equal(#"日", sel.selection["end"].character)
        end)
      end)

      it("sends whole lines for a linewise selection", function()
        local sel = from_marks({ "naïve café", "日本語 テキスト" }, "V", 1, 1, 2, 2147483647)
        assert.are.equal("naïve café\n日本語 テキスト", sel.text)
        assert.are.equal(#"日本語 テキスト", sel.selection["end"].character)
      end)

      describe("a linewise selection whose last line is empty", function()
        -- Claude Code counts `end.line - start.line + 1` lines, one fewer when `end.character` is 0. An end on the
        -- empty line itself would leave that line out of the count.
        it("ends at the start of the next line, with the empty line's line break", function()
          local sel = from_marks({ "abc", "", "def" }, "V", 1, 1, 2, 2147483647)
          assert.are.equal("abc\n\n", sel.text)
          assert.are.same({ line = 2, character = 0 }, sel.selection["end"])
        end)

        it("sends one empty line as its line break, not as an empty selection", function()
          local sel = from_marks({ "", "def" }, "V", 1, 1, 1, 2147483647)
          assert.are.equal("\n", sel.text)
          assert.are.same({ line = 1, character = 0 }, sel.selection["end"])
          assert.is_false(sel.selection.isEmpty)
        end)

        it("ends at character 1 of the empty line when it is the buffer's last line", function()
          -- There is no next line to end on, and character 0 would read as the end of the line before.
          local sel = from_marks({ "abc", "" }, "V", 1, 1, 2, 2147483647)
          assert.are.equal("abc\n", sel.text)
          assert.are.same({ line = 1, character = 1 }, sel.selection["end"])
        end)
      end)

      describe("an end on an empty line, without its line break", function()
        -- Claude Code counts an end at character 0 as the line before, so such an end is character 1.
        local mentions
        local saved_claudecode

        before_each(function()
          mentions = {}
          saved_claudecode = package.loaded["claudecode"]
          package.loaded["claudecode"] = {
            state = { server = {} },
            send_at_mention = function(_, start_line, end_line)
              table.insert(mentions, { start_line, end_line })
              return true
            end,
          }
          selection.state.tracking_enabled = true
        end)

        after_each(function()
          package.loaded["claudecode"] = saved_claudecode
          selection.state.tracking_enabled = false
          _G.vim.o.selection = nil
          _G.vim.o.virtualedit = ""
        end)

        local function mention_of(sel)
          selection.state.latest_selection = sel
          assert.is_true(selection.send_at_mention_for_visual_selection())
          return mentions[#mentions]
        end

        it("keeps a blockwise selection onto an empty row on that row", function()
          -- `1G0<C-v>j$` onto the empty line 2.
          local sel = from_marks({ "abc", "", "x" }, "\22", 1, 1, 2, 2147483647)
          assert.are.equal("abc\n", sel.text)
          assert.are.same({ line = 1, character = 1 }, sel.selection["end"])
          assert.are.same({ 0, 1 }, mention_of(sel))
        end)

        it("keeps an exclusive blockwise selection onto an empty row on that row", function()
          -- Neovim yanks the empty row as part of the block.
          _G.vim.o.selection = "exclusive"
          local sel = from_marks({ "abc", "", "x" }, "\22", 1, 1, 2, 1)
          assert.are.same({ line = 1, character = 1 }, sel.selection["end"])
          assert.are.same({ 0, 1 }, mention_of(sel))
        end)

        it("keeps a charwise selection onto the buffer's empty last line on that line", function()
          -- `10G0vj` when the file ends in an empty line.
          local sel = from_marks({ "abc", "" }, "v", 1, 1, 2, 1)
          assert.are.equal("abc\n", sel.text)
          assert.are.same({ line = 1, character = 1 }, sel.selection["end"])
          assert.are.same({ 0, 1 }, mention_of(sel))
        end)

        it("keeps a selection onto an empty line on that line when 'virtualedit' contains all", function()
          _G.vim.o.virtualedit = "all"
          local sel = from_marks({ "abc", "", "x" }, "v", 1, 1, 2, 1)
          assert.are.equal("abc\n", sel.text)
          assert.are.same({ line = 1, character = 1 }, sel.selection["end"])
        end)

        it("keeps the mention of a linewise selection onto the buffer's empty last line", function()
          local sel = from_marks({ "abc", "" }, "V", 1, 1, 2, 2147483647)
          assert.are.same({ 0, 1 }, mention_of(sel))
        end)
      end)

      describe("past the end of a line", function()
        -- `v$` and `l` past the last character put the end on the line break. Neovim yanks it, except after the
        -- buffer's last line. VS Code ends such a selection at the start of the next line.
        it("includes the line break and ends at the start of the next line", function()
          _G.vim.test.add_buffer(1, "/path/to/test.lua", { "abc", "def" })
          selection.enable(mock_server)
          _G.vim.test.set_mode("v")
          _G.vim._marks = { v = { 0, 1, 1, 0 } }
          _G.vim.test.set_cursor(0, 1, 3)

          selection.update_selection()

          local sent = mock_server.last_broadcast.data
          assert.are.equal("abc\n", sent.text)
          assert.are.same({ line = 0, character = 0 }, sent.selection.start)
          assert.are.same({ line = 1, character = 0 }, sent.selection["end"])
        end)

        it("includes the line break of a multi-line selection's last line", function()
          local sel = from_marks({ "abc", "def", "ghi" }, "v", 1, 1, 2, 4)
          assert.are.equal("abc\ndef\n", sel.text)
          assert.are.same({ line = 2, character = 0 }, sel.selection["end"])
        end)

        it("sends the line break of an empty line", function()
          local sel = from_marks({ "", "def" }, "v", 1, 1, 1, 1)
          assert.are.equal("\n", sel.text)
          assert.are.same({ line = 1, character = 0 }, sel.selection["end"])
          assert.is_false(sel.selection.isEmpty)
        end)

        it("ends at the end of the buffer's last line, without a line break", function()
          local sel = from_marks({ "abc", "def" }, "v", 2, 1, 2, 4)
          assert.are.equal("def", sel.text)
          assert.are.same({ line = 1, character = 3 }, sel.selection["end"])
        end)

        it("ends a blockwise selection at the end of the line", function()
          local sel = from_marks({ "abc", "def", "ghi" }, "\22", 1, 1, 2, 4)
          assert.are.equal("abc\ndef", sel.text)
          assert.are.same({ line = 1, character = 3 }, sel.selection["end"])
        end)

        it("leaves the line break out when 'virtualedit' contains all", function()
          -- There `v$y` yanks a virtual space after the last character, not the line break.
          _G.vim.o.virtualedit = "all"
          local sel = from_marks({ "abc", "def" }, "v", 1, 1, 1, 4)
          _G.vim.o.virtualedit = ""
          assert.are.equal("abc", sel.text)
          assert.are.same({ line = 0, character = 3 }, sel.selection["end"])
        end)

        it("leaves the line break out with 'selection' set to exclusive", function()
          _G.vim.o.selection = "exclusive"
          local sel = from_marks({ "abc", "def" }, "v", 1, 1, 1, 4)
          _G.vim.o.selection = nil
          assert.are.equal("abc", sel.text)
          assert.are.same({ line = 0, character = 3 }, sel.selection["end"])
        end)
      end)

      describe("after a control character", function()
        -- U+0947 DEVANAGARI VOWEL SIGN E is a composing character. On Neovim 0.11+ it is a character of its own
        -- after a TAB, a NUL or an ESC, and `0lvy` on this line yanks only the TAB. Earlier versions join them.
        local line = "x\t\224\165\135y"

        after_each(function()
          _G.vim._has = nil
          _G.vim.o.selection = nil
        end)

        it("ends after the control character alone on Neovim 0.11+", function()
          _G.vim._has = { ["nvim-0.11"] = true }
          local sel = from_marks({ line }, "v", 1, 2, 1, 2)
          assert.are.equal("\t", sel.text)
          assert.are.equal(2, sel.selection["end"].character)
        end)

        it("leaves the composing character out of an exclusive selection on Neovim 0.11+", function()
          _G.vim._has = { ["nvim-0.11"] = true }
          _G.vim.o.selection = "exclusive"
          local sel = from_marks({ line }, "v", 1, 2, 1, 3)
          assert.are.equal("\t", sel.text)
          assert.are.equal(2, sel.selection["end"].character)
        end)

        it("ends after a C1 control alone on Neovim 0.11+", function()
          -- U+0085 NEXT LINE.
          _G.vim._has = { ["nvim-0.11"] = true }
          local sel = from_marks({ "x\194\133\224\165\135y" }, "v", 1, 2, 1, 2)
          assert.are.equal("\194\133", sel.text)
          assert.are.equal(3, sel.selection["end"].character)
        end)

        it("ends after U+200B ZERO WIDTH SPACE alone on Neovim 0.11+", function()
          _G.vim._has = { ["nvim-0.11"] = true }
          local sel = from_marks({ "x\226\128\139\224\165\135y" }, "v", 1, 2, 1, 2)
          assert.are.equal("\226\128\139", sel.text)
          assert.are.equal(4, sel.selection["end"].character)
        end)

        it("leaves the composing character after U+200B out of an exclusive selection on Neovim 0.11+", function()
          _G.vim._has = { ["nvim-0.11"] = true }
          _G.vim.o.selection = "exclusive"
          local sel = from_marks({ "x\226\128\139\224\165\135y" }, "v", 1, 2, 1, 5)
          assert.are.equal("\226\128\139", sel.text)
          assert.are.equal(4, sel.selection["end"].character)
        end)

        it("keeps the composing character with the control character before Neovim 0.11", function()
          local sel = from_marks({ line }, "v", 1, 2, 1, 2)
          assert.are.equal("\t\224\165\135", sel.text)
          assert.are.equal(5, sel.selection["end"].character)
        end)
      end)
    end)

    describe("Select mode", function()
      -- With 'selectmode' containing `cmd`, `v`, `V` and CTRL-V start Select mode, and `gh` always does. It has the
      -- same selection as Visual mode.
      it("sends a charwise Select-mode selection", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta" })
        selection.enable(mock_server)
        _G.vim.test.set_mode("s")
        _G.vim._marks = { v = { 0, 1, 1, 0 } }
        _G.vim.test.set_cursor(0, 1, 2)

        selection.update_selection()

        local sent = mock_server.last_broadcast.data
        assert.are.equal("alp", sent.text)
        assert.are.same({ line = 0, character = 3 }, sent.selection["end"])
      end)

      it("sends whole lines for a linewise Select-mode selection", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta", "gamma" })
        selection.enable(mock_server)
        _G.vim.test.set_mode("S")
        _G.vim._marks = { v = { 0, 1, 3, 0 } }
        _G.vim.test.set_cursor(0, 1, 3)

        selection.update_selection()

        assert.are.equal("alpha beta", mock_server.last_broadcast.data.text)
      end)

      it("flushes the selection when Select mode ends", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta" })
        selection.enable(mock_server)
        _G.vim.test.set_mode("n")
        _G.vim.test.set_cursor(0, 1, 2)
        _G.vim._visualmode = "v"
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 1, 3, 0 } }
        _G.vim.v.event = { old_mode = "s", new_mode = "n" }
        mock_server.last_broadcast = nil

        selection.on_mode_changed()

        assert.are.equal("alp", mock_server.last_broadcast.data.text)
      end)

      it("does not flush when CTRL-O in Select mode switches to Visual mode for one command", function()
        _G.vim.test.add_buffer(1, "/path/to/test.lua", { "alpha beta" })
        selection.enable(mock_server)
        _G.vim._visualmode = "v"
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 1, 3, 0 } }
        _G.vim.v.event = { old_mode = "v", new_mode = "vs" }
        mock_server.last_broadcast = nil

        selection.on_mode_changed()

        assert.is_nil(mock_server.last_broadcast)
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

    describe("is_claude_terminal_buffer", function()
      it("is true for a term:// buffer whose name contains claude", function()
        _G.vim.test.add_buffer(7, "term://~/proj//123:claude --model x", { "" })
        terminal_module.get_active_terminal_bufnr = function()
          return nil
        end
        assert(selection.is_claude_terminal_buffer(7) == true)
      end)

      it("is true for the active Claude terminal buffer", function()
        _G.vim.test.add_buffer(8, "term://~/proj//456:sh", { "" })
        terminal_module.get_active_terminal_bufnr = function()
          return 8
        end
        assert(selection.is_claude_terminal_buffer(8) == true)
      end)

      it("matches claude in the command whatever its case, and keeps a later //<digits>: in the command", function()
        _G.vim.test.add_buffer(12, "term://~/proj//123:Claude --resume", { "" })
        _G.vim.test.add_buffer(13, "term://~/proj//124:sh -c claude-x //9:y", { "" })
        terminal_module.get_active_terminal_bufnr = function()
          return 8
        end
        assert(selection.is_claude_terminal_buffer(12) == true)
        assert(selection.is_claude_terminal_buffer(13) == true)
      end)

      it("is false for a terminal whose cwd, not its command, contains claude", function()
        _G.vim.test.add_buffer(11, "term://~/src/claudecode.nvim//321:/bin/bash", { "" })
        terminal_module.get_active_terminal_bufnr = function()
          return 8
        end
        assert(selection.is_claude_terminal_buffer(11) == false)
      end)

      it("is false for a file buffer and for another terminal", function()
        _G.vim.test.add_buffer(9, "/path/to/test.lua", { "" })
        _G.vim.test.add_buffer(10, "term://~/proj//789:sh", { "" })
        terminal_module.get_active_terminal_bufnr = function()
          return 8
        end
        assert(selection.is_claude_terminal_buffer(9) == false)
        assert(selection.is_claude_terminal_buffer(10) == false)
      end)

      it("is false, and does not raise, for a buffer that was wiped", function()
        local real_get_name = _G.vim.api.nvim_buf_get_name
        _G.vim.api.nvim_buf_get_name = function(bufnr)
          assert(_G.vim._buffers[bufnr] ~= nil, "Invalid buffer id: " .. tostring(bufnr)) -- as Neovim raises
          return real_get_name(bufnr)
        end
        terminal_module.get_active_terminal_bufnr = function()
          return 11 -- the Claude terminal was wiped too
        end

        local ok, result = pcall(selection.is_claude_terminal_buffer, 11)
        _G.vim.api.nvim_buf_get_name = real_get_name

        assert.is_true(ok)
        assert.is_false(result)
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

    describe("a held selection follows the buffer and the cursor", function()
      local original_get_current_buf, original_get_changedtick, original_get_text, original_get_name

      -- nvim_buf_get_text over the mock buffer's lines: byte columns, clamped as Neovim does, an error for a row
      -- that is not there.
      local function mock_get_text(bufnr, start_row, start_col, end_row, end_col)
        local lines = _G.vim._buffers[bufnr].lines
        assert(lines[start_row + 1] ~= nil and lines[end_row + 1] ~= nil, "Index out of bounds")
        local text = {}
        for row = start_row, end_row do
          local line = lines[row + 1]
          table.insert(text, line:sub((row == start_row and start_col or 0) + 1, row == end_row and end_col or #line))
        end
        return text
      end

      -- Runs the callback the plugin registered for an event, with the event name as Neovim passes it, so the
      -- wiring in _create_autocommands is part of every test.
      local function fire_autocmd(event)
        local fired = 0
        for _, autocmd in ipairs(_G.vim._autocmds["ClaudeCodeSelection"].events) do
          for _, name in ipairs(type(autocmd.events) == "table" and autocmd.events or { autocmd.events }) do
            if name == event then
              autocmd.opts.callback({ event = event })
              fired = fired + 1
            end
          end
        end
        assert.are.equal(1, fired, "expected one autocmd for " .. event)
      end

      -- Fake timers: a timer runs only when a test fires it. Each helper below is one key or command with the
      -- autocmds it fires, so a test reads like the keys the user typed.
      local function fire_debounce()
        local timer = selection.state.debounce_timer
        assert(timer ~= nil, "no debounce timer is pending")
        timer:fire()
      end

      local function fire_demotion()
        local timer = selection.state.demotion_timer
        assert(timer ~= nil, "no demotion timer is pending")
        timer:fire()
      end

      -- Default delays: the debounce fires, and the demotion it arms fires before anything else happens.
      local function settle()
        if selection.state.debounce_timer then
          fire_debounce()
        end
        if selection.state.demotion_timer then
          fire_demotion()
        end
      end

      -- v, V or gv: ModeChanged to visual mode.
      local function start_selecting(tick)
        _G.vim._changedtick = tick
        _G.vim.test.set_mode("v")
        _G.vim.v.event = { old_mode = "n", new_mode = "v" }
        selection.on_mode_changed()
      end

      -- Esc: Neovim sets '< and '>, then ModeChanged to normal mode with the cursor where it stands.
      local function release_selection(first_col, last_col, cursor_col)
        _G.vim.test.set_mode("n")
        _G.vim._visualmode = "v"
        _G.vim._marks = { ["'<"] = { 0, 1, first_col, 0 }, ["'>"] = { 0, 1, last_col, 0 } }
        _G.vim.test.set_cursor(0, 1, cursor_col)
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }
        selection.on_mode_changed()
      end

      -- A motion in normal mode: CursorMoved.
      local function move_cursor(col)
        _G.vim.test.set_cursor(0, 1, col)
        fire_autocmd("CursorMoved")
      end

      -- The text changes and TextChanged fires; the cursor stays.
      local function change_lines(tick, lines)
        _G.vim._changedtick = tick
        _G.vim.test.add_buffer(1, "/path/to/a.txt", lines)
        fire_autocmd("TextChanged")
      end

      local function change_text(tick, line)
        change_lines(tick, { line })
      end

      -- x on the cursor: CursorMoved also fires, because the text of the cursor line changed.
      local function delete_at_cursor(tick, line)
        fire_autocmd("CursorMoved")
        change_text(tick, line)
      end

      -- :b <buffer>: BufEnter fires while the window cursor is still at the start of the buffer. Buffer 2 is b.txt.
      local function enter_buffer(bufnr)
        _G.vim.api.nvim_get_current_buf = function()
          return bufnr
        end
        _G.vim.test.set_cursor(0, 1, 0)
        fire_autocmd("BufEnter")
      end

      -- :b <buffer>, then Neovim restores the buffer's last cursor position (col) and CursorMoved fires.
      local function go_to_buffer(bufnr, col)
        enter_buffer(bufnr)
        _G.vim.test.set_cursor(0, 1, col)
        fire_autocmd("CursorMoved")
      end

      -- What Neovim does for nvim_buf_attach: runs the callback of each listener on the buffer. on_lines drops a
      -- listener whose callback returns true. on_reload (:checktime, autoread) ignores what the callback returns and
      -- keeps the listener. on_detach (:edit, :edit!, :bunload) means every listener is gone.
      local function fire_buffer_listeners(bufnr, name)
        local listeners = _G.vim._buf_listeners[bufnr] or {}
        _G.vim._buf_listeners[bufnr] = {}
        for _, listener in ipairs(listeners) do
          -- A callback can attach a new listener, so the list is a fresh one and each callback runs once.
          local detach = listener[name](nil, bufnr)
          if name == "on_reload" or (name == "on_lines" and detach ~= true) then
            table.insert(_G.vim._buf_listeners[bufnr], listener)
          end
        end
      end

      local function assert_claude_holds_cursor(path, col)
        local held = selection.get_latest_selection()
        assert(held ~= nil)
        assert.are.equal(path, held.filePath)
        assert.are.equal(true, held.selection.isEmpty)
        assert.are.equal(col, held.selection.start.character)
        assert.are.equal(held, mock_server.last_broadcast.data)
      end

      before_each(function()
        original_get_current_buf = _G.vim.api.nvim_get_current_buf
        original_get_changedtick = _G.vim.api.nvim_buf_get_changedtick
        original_get_text = _G.vim.api.nvim_buf_get_text
        _G.vim.api.nvim_buf_get_text = mock_get_text
        original_get_name = _G.vim.api.nvim_buf_get_name
        _G.vim.api.nvim_buf_get_name = function(bufnr)
          assert(_G.vim._buffers[bufnr] ~= nil, "Invalid buffer id: " .. tostring(bufnr)) -- as Neovim raises
          return original_get_name(bufnr)
        end
        _G.vim.test.add_buffer(1, "/path/to/a.txt", { "alpha beta gamma" })
        _G.vim.test.add_buffer(2, "/path/to/b.txt", { "one two" })
        _G.vim.test.set_cursor(0, 1, 0)
        _G.vim._buf_listeners = {}
        _G.vim._buffer_windows = {}
      end)

      after_each(function()
        _G.vim.api.nvim_get_current_buf = original_get_current_buf
        _G.vim.api.nvim_buf_get_changedtick = original_get_changedtick
        _G.vim.api.nvim_buf_get_text = original_get_text
        _G.vim.api.nvim_buf_get_name = original_get_name
        _G.vim._buffers[2] = nil
      end)

      it("keeps the selection while the cursor stays and the text is unchanged", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()
        mock_server.last_broadcast = nil

        -- CursorMoved fires again at the same position, as it does after x, and the text is the same.
        fire_autocmd("CursorMoved")
        fire_autocmd("TextChanged")
        settle()

        assert.are.equal("alpha", selection.get_latest_selection().text)
        assert.is_nil(mock_server.last_broadcast)
      end)

      it("keeps the selection while you are in the Claude terminal, and when you come back", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()
        mock_server.last_broadcast = nil

        terminal_module.get_active_terminal_bufnr = function()
          return 2
        end
        go_to_buffer(2, 0)
        settle()
        move_cursor(0)
        start_selecting(5) -- v in the terminal buffer, to copy text from it
        _G.vim.test.set_mode("n")
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }
        selection.on_mode_changed()
        settle()
        go_to_buffer(1, 4)
        settle()

        assert.are.equal("alpha", selection.get_latest_selection().text)
        assert.is_nil(mock_server.last_broadcast)
      end)

      -- Finding 1, HeldEndsWhenMoved (path A): vb, Esc, gv, d. The cursor ends on the column where the first
      -- release left it, so the deleted text looked like a held selection.
      it("ends when you select again and an operator deletes the text (vb Esc gv d)", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 0)
        settle()
        assert.are.equal("alpha", selection.get_latest_selection().text)

        start_selecting(5) -- gv: a new selection replaces the held one
        assert.is_nil(selection.state.cursor_at_flush)
        assert.is_nil(selection.state.last_active_visual_selection)

        -- d: the changedtick moves, visual mode ends, the cursor lands on column 0 again.
        _G.vim._changedtick = 6
        _G.vim.test.add_buffer(1, "/path/to/a.txt", { " beta gamma" })
        _G.vim.test.set_mode("n")
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }
        selection.on_mode_changed()
        fire_autocmd("TextChanged")
        settle()

        assert_claude_holds_cursor("/path/to/a.txt", 0)
      end)

      it("ends at once when an operator consumes a selection that Claude already holds", function()
        selection.enable(mock_server)
        start_selecting(5)

        -- The debounce ran in visual mode: Claude holds the live selection, read at changedtick 5.
        _G.vim._marks = { v = { 0, 1, 1, 0 } } -- the anchor of the selection
        _G.vim.test.set_cursor(0, 1, 4)
        fire_autocmd("CursorMoved")
        fire_debounce()
        assert.are.equal("alpha", selection.get_latest_selection().text)

        -- d: the flush sees the changedtick move and skips. What it skips is not held any more.
        _G.vim._changedtick = 6
        _G.vim.test.add_buffer(1, "/path/to/a.txt", { " beta gamma" })
        _G.vim.test.set_mode("n")
        _G.vim.test.set_cursor(0, 1, 0)
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }
        selection.on_mode_changed()

        -- No timer has fired: the text is gone, so there is no demotion delay for it.
        assert.is_nil(selection.state.last_active_visual_selection)
        assert_claude_holds_cursor("/path/to/a.txt", 0)
        assert.is_nil(selection.state.demotion_timer)
      end)

      -- Starting another selection ends the hold on the first one. An operator then consumes the second selection
      -- before the in-visual debounce, so nothing was sent for it, and the first one is still in latest_selection with
      -- its text intact. The debounce does nothing in the Claude terminal, so the cursor goes out at once.
      it("reports the cursor when an operator consumes a different selection than the held one", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4) -- Claude holds "alpha"
        settle()
        assert.are.equal("alpha", selection.get_latest_selection().text)

        _G.vim.test.add_buffer(1, "/path/to/a.txt", { "alpha beta gamma" })
        start_selecting(5) -- a second selection, on "gamma"
        _G.vim._changedtick = 6
        _G.vim.test.add_buffer(1, "/path/to/a.txt", { "alpha beta gamm" }) -- d deletes its last character
        _G.vim.test.set_mode("n")
        _G.vim.test.set_cursor(0, 1, 14)
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }
        selection.on_mode_changed()

        assert_claude_holds_cursor("/path/to/a.txt", 14) -- no timer has fired
        terminal_module.get_active_terminal_bufnr = function()
          return 2
        end
        go_to_buffer(2, 0)
        settle()

        assert_claude_holds_cursor("/path/to/a.txt", 14)
      end)

      it("does not report early when Claude holds only a cursor and an operator consumes a selection", function()
        selection.enable(mock_server)
        _G.vim.test.set_cursor(0, 1, 2)
        selection.update_selection() -- Claude holds the cursor
        assert.is_true(selection.get_latest_selection().selection.isEmpty)
        mock_server.last_broadcast = nil

        start_selecting(5)
        _G.vim._changedtick = 6
        _G.vim.test.add_buffer(1, "/path/to/a.txt", { "alpha beta gamm" })
        _G.vim.test.set_mode("n")
        _G.vim.test.set_cursor(0, 1, 14)
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }
        selection.on_mode_changed()

        assert.is_nil(mock_server.last_broadcast) -- nothing to replace: the debounce reports the cursor
      end)

      it("reads the live selection again at once when its text changes in visual mode", function()
        selection.enable(mock_server)
        start_selecting(5)
        _G.vim._marks = { v = { 0, 1, 1, 0 } }
        _G.vim.test.set_cursor(0, 1, 4)
        fire_autocmd("CursorMoved")
        fire_debounce()
        assert.are.equal("alpha", selection.get_latest_selection().text) -- read at changedtick 5

        _G.vim._changedtick = 6
        _G.vim.test.add_buffer(1, "/path/to/a.txt", { "ALPHA beta gamma" }) -- a plugin edits while you select
        _G.vim.test.set_cursor(0, 1, 3)
        fire_autocmd("CursorMoved")

        assert.are.equal("ALPH", selection.get_latest_selection().text) -- before the debounce fires
      end)

      -- Finding 1, HeldEndsWhenMoved (path B): ve, Esc, l, h within one debounce.
      it("ends when the cursor moves away and back before the debounce fires (ve Esc l h)", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()
        assert.are.equal("alpha", selection.get_latest_selection().text)

        move_cursor(5) -- l
        move_cursor(4) -- h, 30 ms later: the debounce has not fired yet
        settle()

        assert_claude_holds_cursor("/path/to/a.txt", 4)
      end)

      -- Finding 2, NoDeletedText: viw, Esc, x, x.
      it("ends when you edit the selected text without moving the cursor (viw Esc x x)", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()
        assert.are.equal("alpha", selection.get_latest_selection().text)

        delete_at_cursor(6, "alph beta gamma") -- x
        assert_claude_holds_cursor("/path/to/a.txt", 4) -- at once, before any timer fires
        settle()
        assert_claude_holds_cursor("/path/to/a.txt", 4)

        delete_at_cursor(7, "alphbeta gamma") -- x
        settle()
        assert_claude_holds_cursor("/path/to/a.txt", 4)
      end)

      it("ends when the selected text changes without CursorMoved (a plugin applies an edit)", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()
        assert.are.equal("alpha", selection.get_latest_selection().text)

        change_text(6, "alph beta gamma")
        settle()

        assert_claude_holds_cursor("/path/to/a.txt", 4)
      end)

      -- The debounce does nothing in the Claude terminal, so text that is gone must not wait for it.
      it("holds no deleted text when you go to the Claude terminal right after the edit", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()

        delete_at_cursor(6, "alph beta gamma") -- x
        terminal_module.get_active_terminal_bufnr = function()
          return 2
        end
        go_to_buffer(2, 0)
        settle()

        assert_claude_holds_cursor("/path/to/a.txt", 4)
      end)

      it("reports the cursor at once when you move away, so the Claude terminal does not keep the selection", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()

        move_cursor(5) -- l: no timer has fired
        assert_claude_holds_cursor("/path/to/a.txt", 5)
        terminal_module.get_active_terminal_bufnr = function()
          return 2
        end
        go_to_buffer(2, 0)
        settle()

        assert_claude_holds_cursor("/path/to/a.txt", 5)
      end)

      it("keeps the selection when the buffer changes after its range", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()
        mock_server.last_broadcast = nil

        change_lines(6, { "alpha beta gamma", "a second line" }) -- a plugin appends a line: the changedtick moves
        settle()

        assert.are.equal("alpha", selection.get_latest_selection().text)
        assert.is_nil(mock_server.last_broadcast)
      end)

      it("ends the selection when the buffer loses the line it ended on", function()
        _G.vim.test.add_buffer(1, "/path/to/a.txt", { "alpha beta", "gamma delta" })
        selection.enable(mock_server)
        start_selecting(5)
        _G.vim.test.set_mode("n")
        _G.vim._visualmode = "v"
        _G.vim._marks = { ["'<"] = { 0, 1, 1, 0 }, ["'>"] = { 0, 2, 5, 0 } }
        _G.vim.test.set_cursor(0, 2, 4)
        _G.vim.v.event = { old_mode = "v", new_mode = "n" }
        selection.on_mode_changed()
        settle()
        assert.are.equal("alpha beta\ngamma", selection.get_latest_selection().text)

        change_lines(6, { "alpha beta" }) -- there is no row 1 to read any more
        settle()

        assert.are.equal(true, selection.get_latest_selection().selection.isEmpty)
      end)

      it("ends the selection when a change before its range shifts it", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()

        change_lines(6, { "see: alpha beta gamma" }) -- the range 0-5 now holds "see: "
        settle()

        assert_claude_holds_cursor("/path/to/a.txt", 4)
      end)

      it("holds no deleted text after you leave, come back, edit and go to the terminal quickly", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        fire_debounce() -- arms the demotion
        local demotion = selection.state.demotion_timer
        assert(demotion ~= nil)

        enter_buffer(2)
        demotion:fire() -- in b.txt: the held state of a.txt is resolved, and nothing is reported yet
        assert.are.equal("alpha", selection.get_latest_selection().text)
        enter_buffer(1)
        _G.vim.test.set_cursor(0, 1, 4)
        change_text(6, "alph beta gamma") -- x, still before the debounce fires
        terminal_module.get_active_terminal_bufnr = function()
          return 2
        end
        go_to_buffer(2, 0)
        settle()

        assert_claude_holds_cursor("/path/to/a.txt", 4)
      end)

      it("keeps the selection when its demotion is armed just before you enter the Claude terminal", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        fire_debounce() -- arms the demotion
        local demotion = selection.state.demotion_timer
        assert(demotion ~= nil)
        terminal_module.get_active_terminal_bufnr = function()
          return 2
        end

        go_to_buffer(2, 0)
        assert.is_nil(selection.state.demotion_timer) -- cancelled when the terminal is entered
        demotion:fire() -- the old timer fires before the terminal's own debounce, and must do nothing
        go_to_buffer(1, 4)
        settle()

        assert.are.equal("alpha", selection.get_latest_selection().text)
      end)

      it("listens for text changes made in Insert mode too", function()
        selection.enable(mock_server)

        local events = {}
        for _, autocmd in ipairs(_G.vim._autocmds["ClaudeCodeSelection"].events) do
          for _, event in ipairs(type(autocmd.events) == "table" and autocmd.events or { autocmd.events }) do
            events[event] = true
          end
        end

        assert.is_true(events["TextChanged"])
        assert.is_true(events["TextChangedI"])
        assert.is_true(events["TextChangedP"])
      end)

      -- Neovim fires BufEnter for a new Claude terminal before the buffer has a name and before the provider
      -- registers it, so terminal.get_active_terminal_bufnr() is still nil then.
      it("keeps the selection when a new Claude terminal is entered before it is registered", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()
        mock_server.last_broadcast = nil

        _G.vim.test.add_buffer(2, "", { "" })
        enter_buffer(2)
        terminal_module.get_active_terminal_bufnr = function()
          return 2 -- registered right after BufEnter
        end
        settle()
        go_to_buffer(1, 4)
        settle()

        assert.are.equal("alpha", selection.get_latest_selection().text)
        assert.is_nil(mock_server.last_broadcast)
      end)

      -- A popup that wipes itself when you leave it (bufhidden=wipe): its buffer number is gone at the next event.
      it("ends the selection without an error when the buffer you visited is wiped", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()

        enter_buffer(2)
        _G.vim._buffers[2] = nil -- wiped as you leave it
        go_to_buffer(1, 4) -- BufEnter and CursorMoved in a.txt must not raise
        settle()

        assert_claude_holds_cursor("/path/to/a.txt", 4)
        move_cursor(5) -- and every later event still works
        assert.is_not_nil(selection.state.debounce_timer)
        settle()
        assert_claude_holds_cursor("/path/to/a.txt", 5)
      end)

      it("keeps the selection through a terminal that only its name says is Claude's", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()
        mock_server.last_broadcast = nil

        -- terminal.provider = "none" with a :terminal buffer: no provider registers it
        _G.vim.test.add_buffer(2, "term://~/project//4242:claude", { "claude> hello" })
        go_to_buffer(2, 0)
        settle()
        go_to_buffer(1, 4)
        settle()

        assert.are.equal("alpha", selection.get_latest_selection().text)
        assert.is_nil(mock_server.last_broadcast)
      end)

      it("does not read the changedtick of the Claude terminal as an edit of the selection", function()
        local ticks = { [1] = 5, [2] = 5 }
        _G.vim.api.nvim_buf_get_changedtick = function(bufnr)
          return ticks[bufnr]
        end
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()
        mock_server.last_broadcast = nil

        terminal_module.get_active_terminal_bufnr = function()
          return 2
        end
        ticks[2] = 500 -- the terminal's own text changes all the time
        go_to_buffer(2, 0)
        settle()
        go_to_buffer(1, 4)
        settle()

        assert.are.equal("alpha", selection.get_latest_selection().text)
        assert.is_nil(mock_server.last_broadcast)
      end)

      -- TextChanged fires only for the current buffer. A reload (:checktime, autoread) or a plugin's edit changes
      -- the buffer of the held selection while you are in the Claude terminal, which keeps the selection and does
      -- not update it. A listener on that buffer sees the change.
      describe("when the buffer of the held selection changes while you are in the Claude terminal", function()
        local ticks

        -- Holds "alpha" in buffer 1, then goes to the Claude terminal, buffer 2.
        local function hold_alpha_and_enter_the_terminal()
          ticks = { [1] = 5, [2] = 5 }
          _G.vim.api.nvim_buf_get_changedtick = function(bufnr)
            return ticks[bufnr]
          end
          selection.enable(mock_server)
          start_selecting(5)
          release_selection(1, 5, 4)
          settle()
          terminal_module.get_active_terminal_bufnr = function()
            return 2
          end
          go_to_buffer(2, 0)
          settle()
          assert.are.equal("alpha", selection.get_latest_selection().text)
          mock_server.last_broadcast = nil
        end

        local function change_buffer_1(lines)
          ticks[1] = ticks[1] + 1
          _G.vim.test.add_buffer(1, "/path/to/a.txt", lines)
          fire_buffer_listeners(1, "on_lines")
        end

        it("listens to the buffer of a held selection once", function()
          selection.enable(mock_server)
          start_selecting(5)
          release_selection(1, 5, 4)
          start_selecting(5)
          release_selection(1, 5, 4)

          assert.are.equal(1, #_G.vim._buf_listeners[1])
        end)

        it("sends the cursor where the buffer's window has it, not the deleted text", function()
          hold_alpha_and_enter_the_terminal()
          _G.vim._buffer_windows[1] = { 7 }
          _G.vim.test.set_cursor(7, 1, 3)

          change_buffer_1({ "beta gamma" })

          assert_claude_holds_cursor("/path/to/a.txt", 3)
          assert.is_nil(selection.state.cursor_at_flush)
          assert.is_nil(selection.state.last_active_visual_selection)
        end)

        it("sends the position where it was released, kept inside the text, when no window shows the buffer", function()
          hold_alpha_and_enter_the_terminal()

          change_buffer_1({ "be" })

          assert_claude_holds_cursor("/path/to/a.txt", 2)
        end)

        it("puts the release position on the first byte of a multibyte character", function()
          hold_alpha_and_enter_the_terminal()
          selection.state.cursor_at_flush.pos = { 1, 1 }

          change_buffer_1({ "é" }) -- two bytes: column 1 is its continuation byte

          assert_claude_holds_cursor("/path/to/a.txt", 0)
        end)

        it("keeps the release position inside the lines that are there", function()
          hold_alpha_and_enter_the_terminal()
          _G.vim.test.add_buffer(1, "/path/to/a.txt", { "alpha beta gamma", "second", "third" })
          selection.state.cursor_at_flush.pos = { 3, 2 }

          change_buffer_1({ "x" })

          assert_claude_holds_cursor("/path/to/a.txt", 1)
          assert.are.equal(0, selection.get_latest_selection().selection.start.line)
        end)

        it("keeps the selection when the change leaves its text in place", function()
          hold_alpha_and_enter_the_terminal()

          change_buffer_1({ "alpha beta gamma", "a second line" })

          assert.are.equal("alpha", selection.get_latest_selection().text)
          assert.is_nil(mock_server.last_broadcast)
        end)

        it("listens again after :edit! detaches the listener, and sees the change of that reload", function()
          hold_alpha_and_enter_the_terminal()

          ticks[1] = 6
          _G.vim.test.add_buffer(1, "/path/to/a.txt", { "beta gamma" })
          fire_buffer_listeners(1, "on_detach") -- :edit!

          assert_claude_holds_cursor("/path/to/a.txt", 4)
        end)

        it("listens again after :edit! that left the text in place", function()
          hold_alpha_and_enter_the_terminal()

          ticks[1] = 6
          fire_buffer_listeners(1, "on_detach")

          assert.are.equal("alpha", selection.get_latest_selection().text)
          assert.are.equal(1, #_G.vim._buf_listeners[1])
          change_buffer_1({ "beta gamma" })
          assert_claude_holds_cursor("/path/to/a.txt", 4)
        end)

        it("reports a change of the buffer you are in at once, before TextChanged", function()
          selection.enable(mock_server)
          ticks = { [1] = 5 }
          _G.vim.api.nvim_buf_get_changedtick = function(bufnr)
            return ticks[bufnr]
          end
          start_selecting(5)
          release_selection(1, 5, 4)
          settle()
          mock_server.last_broadcast = nil

          -- A listener runs before TextChanged: the change is reported once, by whichever comes first.
          ticks[1] = 6
          _G.vim.test.add_buffer(1, "/path/to/a.txt", { "beta gamma" })
          fire_buffer_listeners(1, "on_lines")

          assert_claude_holds_cursor("/path/to/a.txt", 4)
        end)

        it("does not send a cursor while you are in another file: the debounce does", function()
          selection.enable(mock_server)
          ticks = { [1] = 5, [2] = 5 }
          _G.vim.api.nvim_buf_get_changedtick = function(bufnr)
            return ticks[bufnr]
          end
          start_selecting(5)
          release_selection(1, 5, 4)
          settle()
          enter_buffer(2) -- b.txt, not the Claude terminal, and the debounce has not fired yet
          mock_server.last_broadcast = nil

          change_buffer_1({ "beta gamma" })

          assert.are.equal("alpha", selection.get_latest_selection().text)
          assert.is_nil(mock_server.last_broadcast)
        end)

        it("does not read a buffer that was unloaded while you stay in the terminal", function()
          hold_alpha_and_enter_the_terminal()
          ticks[1] = 6
          _G.vim._buffers[1] = nil -- :bunload

          assert.has_no.errors(function()
            fire_autocmd("CursorMoved") -- in the terminal
          end)

          assert.are.equal("alpha", selection.get_latest_selection().text)
          assert.is_nil(mock_server.last_broadcast)
        end)

        -- A new Claude terminal is not registered when BufEnter fires. The file changed before that, while you were in
        -- another file, where nothing needs to be sent yet. The debounce is the first event that knows the terminal.
        it("checks the held text in the debounce when the terminal was not registered at BufEnter", function()
          ticks = { [1] = 5, [2] = 5, [3] = 5 }
          _G.vim.api.nvim_buf_get_changedtick = function(bufnr)
            return ticks[bufnr]
          end
          _G.vim.test.add_buffer(3, "/path/to/c.txt", { "three" })
          selection.enable(mock_server)
          start_selecting(5)
          release_selection(1, 5, 4)
          settle()
          go_to_buffer(3, 0) -- c.txt, a file
          change_buffer_1({ "beta gamma" })
          assert.are.equal("alpha", selection.get_latest_selection().text) -- nothing to send in c.txt yet

          terminal_module.get_active_terminal_bufnr = function()
            return 3 -- the terminal in buffer 3 is registered now
          end
          _G.vim.test.add_buffer(3, "term://~/project//4242:claude", { "claude> " })
          fire_debounce()

          assert_claude_holds_cursor("/path/to/a.txt", 4)
          _G.vim._buffers[3] = nil
        end)

        it("checks once after a burst of changes, such as a :%s", function()
          hold_alpha_and_enter_the_terminal()
          local original_schedule = _G.vim.schedule
          local queue = {}
          _G.vim.schedule = function(fn)
            table.insert(queue, fn)
          end

          ticks[1] = 6
          _G.vim.test.add_buffer(1, "/path/to/a.txt", { "beta gamma" })
          for _ = 1, 5 do
            fire_buffer_listeners(1, "on_lines")
          end
          _G.vim.schedule = original_schedule

          assert.are.equal(1, #queue)
          queue[1]()
          assert_claude_holds_cursor("/path/to/a.txt", 4)
        end)

        it("sees the change of a reload (:checktime), which keeps the listener", function()
          hold_alpha_and_enter_the_terminal()

          ticks[1] = 6
          _G.vim.test.add_buffer(1, "/path/to/a.txt", { "beta gamma" })
          fire_buffer_listeners(1, "on_reload")

          assert_claude_holds_cursor("/path/to/a.txt", 4)
          assert.are.equal(1, #_G.vim._buf_listeners[1])
        end)

        -- on_reload cannot detach a listener: if it forgot the buffer, the next read would attach a second one.
        it("keeps one listener when a reload comes while Claude holds only a cursor", function()
          hold_alpha_and_enter_the_terminal()
          change_buffer_1({ "beta gamma" }) -- Claude holds the cursor now
          fire_buffer_listeners(1, "on_reload")
          assert.are.equal(1, #_G.vim._buf_listeners[1])

          go_to_buffer(1, 0)
          start_selecting(6)
          release_selection(1, 4, 3) -- Claude holds a selection of buffer 1 again

          assert.are.equal(1, #_G.vim._buf_listeners[1])
        end)

        it("stops listening when Claude no longer holds a selection", function()
          hold_alpha_and_enter_the_terminal()
          change_buffer_1({ "beta gamma" }) -- Claude holds the cursor now

          change_buffer_1({ "beta gamma!" })

          assert.are.equal(0, #_G.vim._buf_listeners[1])
          assert.is_nil(selection.state.watched_buffers[1])
        end)

        it("stops listening when tracking is disabled", function()
          hold_alpha_and_enter_the_terminal()
          selection.disable()

          change_buffer_1({ "beta gamma" })

          assert.are.equal(0, #_G.vim._buf_listeners[1])
        end)

        it("does not read a buffer that was unloaded", function()
          hold_alpha_and_enter_the_terminal()
          _G.vim._buffers[1] = nil -- :bunload

          assert.has_no.errors(function()
            fire_buffer_listeners(1, "on_detach")
          end)

          assert.are.equal("alpha", selection.get_latest_selection().text)
          assert.is_nil(mock_server.last_broadcast)
        end)
      end)

      -- Finding 3, SameFile: a long visual_demotion_delay_ms, so the demotion is still pending (it never fires
      -- in this test until the end).
      it("never holds another file's cursor after you come back (:b b.txt, :b a.txt)", function()
        selection.enable(mock_server, 1000)
        start_selecting(5)
        release_selection(1, 5, 4)
        fire_debounce() -- arms the demotion; the selection is held
        assert.are.equal("alpha", selection.get_latest_selection().text)
        local pending_demotion = selection.state.demotion_timer
        assert(pending_demotion ~= nil)

        go_to_buffer(2, 0)
        fire_debounce()
        assert_claude_holds_cursor("/path/to/b.txt", 0)

        go_to_buffer(1, 4) -- the cursor is back where it was released
        fire_debounce()
        assert.are.equal(pending_demotion, selection.state.demotion_timer)
        pending_demotion:fire()

        assert_claude_holds_cursor("/path/to/a.txt", 4)
      end)

      it("never holds the selection after you visit another file and come back inside one debounce", function()
        selection.enable(mock_server)
        start_selecting(5)
        release_selection(1, 5, 4)
        settle()
        assert.are.equal("alpha", selection.get_latest_selection().text)

        -- BufEnter only: the cursor lands on the same line and column, so CursorMoved does not fire.
        enter_buffer(2)
        enter_buffer(1)
        _G.vim.test.set_cursor(0, 1, 4) -- back where it was released, but you left the file
        settle()

        assert_claude_holds_cursor("/path/to/a.txt", 4)
      end)

      it("ends the hold when a pending-demotion update reports the cursor, even if no CursorMoved came", function()
        selection.enable(mock_server, 1000)
        start_selecting(5)
        release_selection(1, 5, 4)
        fire_debounce()
        assert(selection.state.demotion_timer ~= nil)

        _G.vim.test.set_cursor(0, 1, 6) -- moved, and no CursorMoved reached the plugin
        selection.update_selection()
        assert_claude_holds_cursor("/path/to/a.txt", 6)
        assert.is_nil(selection.state.cursor_at_flush)

        _G.vim.test.set_cursor(0, 1, 4) -- back at the position of the release
        selection.update_selection()
        assert_claude_holds_cursor("/path/to/a.txt", 4)
      end)

      -- Finding 4, ClaudeSeesCursor: a long visual_demotion_delay_ms, release, move right, wait, move back.
      it("never holds a cursor position you left (Esc l, wait, h)", function()
        selection.enable(mock_server, 1000)
        start_selecting(5)
        release_selection(1, 5, 4)
        fire_debounce()
        local pending_demotion = selection.state.demotion_timer
        assert(pending_demotion ~= nil)

        move_cursor(5) -- l
        fire_debounce()
        assert_claude_holds_cursor("/path/to/a.txt", 5)

        move_cursor(4) -- h
        fire_debounce()
        assert_claude_holds_cursor("/path/to/a.txt", 4)

        pending_demotion:fire()
        assert_claude_holds_cursor("/path/to/a.txt", 4)
      end)
    end)
  end)
end)
