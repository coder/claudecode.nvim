if not _G.vim then
  _G.vim = { ---@type vim_global_api
    schedule_wrap = function(fn)
      return fn
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
        if mark == "'<" then
          return { 0, 1, 1, 0 }
        elseif mark == "'>" then
          return { 0, 5, 10, 0 }
        end
        return { 0, 0, 0, 0 }
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
      timer_stop = function(_timer) -- Prefix unused param with underscore
        return true
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
