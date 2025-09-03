--- Mock implementation of the Neovim API for tests.

--- Spy functionality for testing.
--- Provides a `spy.on` method to wrap functions and track their calls.
if _G.spy == nil then
  _G.spy = {
    on = function(table, method_name)
      local original = table[method_name]
      local calls = {}

      table[method_name] = function(...)
        table.insert(calls, { vals = { ... } })
        if original then
          return original(...)
        end
      end

      table[method_name].calls = calls
      table[method_name].spy = function()
        return {
          was_called = function(n)
            assert(#calls == n, "Expected " .. n .. " calls, got " .. #calls)
            return true
          end,
          was_not_called = function()
            assert(#calls == 0, "Expected 0 calls, got " .. #calls)
            return true
          end,
          was_called_with = function(...)
            local expected = { ... }
            assert(#calls > 0, "Function was never called")

            local last_call = calls[#calls].vals
            for i, v in ipairs(expected) do
              if type(v) == "table" and v._type == "match" then
                -- Use custom matcher (simplified for this mock)
                if v._match == "is_table" and type(last_call[i]) ~= "table" then
                  assert(false, "Expected table at arg " .. i)
                end
              else
                assert(last_call[i] == v, "Argument mismatch at position " .. i)
              end
            end
            return true
          end,
        }
      end

      return table[method_name]
    end,
  }

  --- Simple table matcher for spy assertions.
  --- Allows checking if an argument was a table.
  _G.match = {
    is_table = function()
      return { _type = "match", _match = "is_table" }
    end,
  }
end

local vim = {
  _buffers = {},
  _windows = { [1000] = { buf = 1, width = 80 } }, -- winid -> { buf, width, cursor, config }
  _win_tab = { [1000] = 1 }, -- winid -> tabpage
  _tab_windows = { [1] = { 1000 } }, -- tabpage -> { winids }
  _next_winid = 1001,
  _commands = {},
  _autocmds = {},
  _vars = {},
  _options = {},
  _current_window = 1000,
  _tabs = { [1] = true },
  _current_tabpage = 1,

  api = {
    nvim_create_user_command = function(name, callback, opts)
      vim._commands[name] = {
        callback = callback,
        opts = opts,
      }
    end,

    nvim_create_augroup = function(name, opts)
      vim._autocmds[name] = {
        opts = opts,
        events = {},
      }
      return name
    end,

    nvim_create_autocmd = function(events, opts)
      local group = opts.group or "default"
      if not vim._autocmds[group] then
        vim._autocmds[group] = {
          opts = {},
          events = {},
        }
      end

      local id = #vim._autocmds[group].events + 1
      vim._autocmds[group].events[id] = {
        events = events,
        opts = opts,
      }

      return id
    end,

    nvim_clear_autocmds = function(opts)
      if opts.group then
        vim._autocmds[opts.group] = nil
      end
    end,

    nvim_get_current_buf = function()
      return 1
    end,

    nvim_buf_get_name = function(bufnr)
      return vim._buffers[bufnr] and vim._buffers[bufnr].name or ""
    end,

    nvim_win_get_cursor = function(winid)
      return vim._windows[winid] and vim._windows[winid].cursor or { 1, 0 }
    end,

    nvim_buf_get_lines = function(bufnr, start, end_line, strict)
      if not vim._buffers[bufnr] then
        return {}
      end

      local lines = vim._buffers[bufnr].lines or {}
      local result = {}

      for i = start + 1, end_line do
        table.insert(result, lines[i] or "")
      end

      return result
    end,

    nvim_buf_get_option = function(bufnr, name)
      if not vim._buffers[bufnr] then
        return nil
      end

      return vim._buffers[bufnr].options and vim._buffers[bufnr].options[name] or nil
    end,

    nvim_buf_delete = function(bufnr, opts)
      vim._buffers[bufnr] = nil
    end,

    nvim_echo = function(chunks, history, opts)
      -- Store the last echo message for test assertions.
      vim._last_echo = {
        chunks = chunks,
        history = history,
        opts = opts,
      }
    end,

    nvim_err_writeln = function(msg)
      vim._last_error = msg
    end,
    nvim_buf_set_name = function(bufnr, name)
      if vim._buffers[bufnr] then
        vim._buffers[bufnr].name = name
      else
        -- TODO: Consider if error handling for 'buffer not found' is needed for tests.
      end
    end,
    nvim_set_option_value = function(name, value, opts)
      -- Note: This mock simplifies 'scope = "local"' handling.
      -- In a real nvim_set_option_value, 'local' scope would apply to a specific
      -- buffer or window. Here, it's stored in a general options table if not
      -- a buffer-local option, or in the buffer's options table if `opts.buf` is provided.
      -- A more complex mock might be needed for intricate scope-related tests.
      if opts and opts.buf then
        if vim._buffers[opts.buf] then
          if not vim._buffers[opts.buf].options then
            vim._buffers[opts.buf].options = {}
          end
          vim._buffers[opts.buf].options[name] = value
        else
          -- TODO: Consider if error handling for 'buffer not found' is needed for tests.
        end
      else
        vim._options[name] = value
      end
    end,

    -- Add missing API functions for diff tests
    nvim_create_buf = function(listed, scratch)
      local bufnr = #vim._buffers + 1
      vim._buffers[bufnr] = {
        name = "",
        lines = {},
        options = {},
        listed = listed,
        scratch = scratch,
      }
      return bufnr
    end,

    nvim_buf_set_lines = function(bufnr, start, end_line, strict_indexing, replacement)
      if not vim._buffers[bufnr] then
        vim._buffers[bufnr] = { lines = {}, options = {} }
      end
      vim._buffers[bufnr].lines = replacement or {}
    end,

    nvim_buf_set_option = function(bufnr, name, value)
      if not vim._buffers[bufnr] then
        vim._buffers[bufnr] = { lines = {}, options = {} }
      end
      if not vim._buffers[bufnr].options then
        vim._buffers[bufnr].options = {}
      end
      vim._buffers[bufnr].options[name] = value
    end,

    nvim_buf_is_valid = function(bufnr)
      return vim._buffers[bufnr] ~= nil
    end,

    nvim_buf_is_loaded = function(bufnr)
      -- In our mock, all valid buffers are considered loaded
      return vim._buffers[bufnr] ~= nil
    end,

    nvim_list_bufs = function()
      -- Return a list of buffer IDs
      local bufs = {}
      for bufnr, _ in pairs(vim._buffers) do
        table.insert(bufs, bufnr)
      end
      return bufs
    end,

    nvim_buf_call = function(bufnr, callback)
      -- Mock implementation - just call the callback
      if vim._buffers[bufnr] then
        return callback()
      end
      error("Invalid buffer id: " .. tostring(bufnr))
    end,

    nvim_get_autocmds = function(opts)
      if opts and opts.group then
        local group = vim._autocmds[opts.group]
        if group and group.events then
          local result = {}
          for id, event in pairs(group.events) do
            table.insert(result, {
              id = id,
              group = opts.group,
              event = event.events,
              pattern = event.opts.pattern,
              callback = event.opts.callback,
            })
          end
          return result
        end
      end
      return {}
    end,

    nvim_del_autocmd = function(id)
      -- Find and remove autocmd by id
      for group_name, group in pairs(vim._autocmds) do
        if group.events and group.events[id] then
          group.events[id] = nil
          return
        end
      end
    end,

    nvim_get_current_win = function()
      return vim._current_window
    end,

    nvim_set_current_win = function(winid)
      -- Mock implementation - just track that it was called
      vim._current_window = winid
      return true
    end,

    nvim_list_wins = function()
      -- Return a list of window IDs for the current tab
      local wins = {}
      local list = vim._tab_windows[vim._current_tabpage] or {}
      for _, winid in ipairs(list) do
        if vim._windows[winid] then
          table.insert(wins, winid)
        end
      end
      if #wins == 0 then
        -- Always have at least one window
        table.insert(wins, vim._current_window)
      end
      return wins
    end,

    nvim_win_set_buf = function(winid, bufnr)
      if not vim._windows[winid] then
        vim._windows[winid] = {}
      end
      local old_buf = vim._windows[winid].buf
      vim._windows[winid].buf = bufnr
      -- If old buffer is no longer displayed in any window, and has bufhidden=wipe, delete it
      if old_buf and vim._buffers[old_buf] then
        local still_visible = false
        for _, w in pairs(vim._windows) do
          if w.buf == old_buf then
            still_visible = true
            break
          end
        end
        if not still_visible then
          local opts = vim._buffers[old_buf].options or {}
          if opts.bufhidden == "wipe" then
            vim._buffers[old_buf] = nil
          end
        end
      end
    end,

    nvim_win_get_buf = function(winid)
      if vim._windows[winid] then
        return vim._windows[winid].buf or 1
      end
      return 1 -- Default buffer
    end,

    nvim_win_is_valid = function(winid)
      return vim._windows[winid] ~= nil
    end,

    nvim_win_close = function(winid, force)
      local old_buf = vim._windows[winid] and vim._windows[winid].buf
      vim._windows[winid] = nil
      -- remove from tab mapping
      local tab = vim._win_tab[winid]
      if tab and vim._tab_windows[tab] then
        local new_list = {}
        for _, w in ipairs(vim._tab_windows[tab]) do
          if w ~= winid then
            table.insert(new_list, w)
          end
        end
        vim._tab_windows[tab] = new_list
      end
      vim._win_tab[winid] = nil
      -- Apply bufhidden=wipe if now hidden
      if old_buf and vim._buffers[old_buf] then
        local still_visible = false
        for _, w in pairs(vim._windows) do
          if w.buf == old_buf then
            still_visible = true
            break
          end
        end
        if not still_visible then
          local opts = vim._buffers[old_buf].options or {}
          if opts.bufhidden == "wipe" then
            vim._buffers[old_buf] = nil
          end
        end
      end
    end,

    nvim_win_call = function(winid, callback)
      -- Mock implementation - just call the callback
      if vim._windows[winid] then
        return callback()
      end
      error("Invalid window id: " .. tostring(winid))
    end,

    nvim_win_get_config = function(winid)
      -- Mock implementation - return empty config for non-floating windows
      if vim._windows[winid] then
        return vim._windows[winid].config or {}
      end
      return {}
    end,

    nvim_win_set_width = function(winid, width)
      if vim._windows[winid] then
        vim._windows[winid].width = width
      end
    end,

    nvim_win_get_width = function(winid)
      return (vim._windows[winid] and vim._windows[winid].width) or 80
    end,

    nvim_get_current_tabpage = function()
      return vim._current_tabpage
    end,

    nvim_set_current_tabpage = function(tab)
      if vim._tabs[tab] then
        vim._current_tabpage = tab
      end
    end,

    nvim_tabpage_is_valid = function(tab)
      return vim._tabs[tab] == true
    end,

    nvim_tabpage_get_number = function(tab)
      return tab
    end,

    nvim_tabpage_set_var = function(tabpage, name, value)
      -- Mock tabpage variable setting
    end,

    nvim_win_get_tabpage = function(winid)
      return vim._win_tab[winid] or vim._current_tabpage
    end,

    nvim_buf_line_count = function(bufnr)
      local b = vim._buffers[bufnr]
      if not b or not b.lines then
        return 0
      end
      return #b.lines
    end,
  },

  fn = {
    getpid = function()
      return 12345
    end,

    expand = function(path)
      return path:gsub("~", "/home/user")
    end,

    filereadable = function(path)
      -- Check if file actually exists
      local file = io.open(path, "r")
      if file then
        file:close()
        return 1
      end
      return 0
    end,

    bufnr = function(name)
      for bufnr, buf in pairs(vim._buffers) do
        if buf.name == name then
          return bufnr
        end
      end
      return -1
    end,

    buflisted = function(bufnr)
      return vim._buffers[bufnr] and vim._buffers[bufnr].listed and 1 or 0
    end,

    mkdir = function(path, flags)
      return 1
    end,

    getpos = function(mark)
      if mark == "'<" then
        return { 0, 1, 1, 0 }
      elseif mark == "'>" then
        return { 0, 1, 10, 0 }
      end
      return { 0, 0, 0, 0 }
    end,

    mode = function()
      return "n"
    end,

    fnameescape = function(name)
      return name:gsub(" ", "\\ ")
    end,

    getcwd = function()
      return "/home/user/project"
    end,

    fnamemodify = function(path, modifier)
      if modifier == ":t" then
        return path:match("([^/]+)$") or path
      end
      return path
    end,

    has = function(feature)
      if feature == "nvim-0.8.0" then
        return 1
      end
      return 0
    end,
    stdpath = function(type)
      if type == "cache" then
        return "/tmp/nvim_mock_cache"
      elseif type == "config" then
        return "/tmp/nvim_mock_config"
      elseif type == "data" then
        return "/tmp/nvim_mock_data"
      elseif type == "temp" then
        return "/tmp"
      else
        return "/tmp/nvim_mock_stdpath_" .. type
      end
    end,
    tempname = function()
      -- Return a somewhat predictable temporary name for testing.
      -- The random number ensures some uniqueness if called multiple times.
      return "/tmp/nvim_mock_tempfile_" .. math.random(1, 100000)
    end,

    writefile = function(lines, filename, flags)
      -- Mock implementation - just record that it was called
      vim._written_files = vim._written_files or {}
      vim._written_files[filename] = lines
      return 0
    end,

    localtime = function()
      return os.time()
    end,
  },

  cmd = function(command)
    -- Store the last command for test assertions.
    vim._last_command = command
    -- Implement minimal behavior for essential commands
    if command == "tabnew" then
      -- Create new tab with a new window and an unnamed buffer
      local new_tab = 1
      for k, _ in pairs(vim._tabs) do
        if k >= new_tab then
          new_tab = k + 1
        end
      end
      vim._tabs[new_tab] = true
      vim._current_tabpage = new_tab

      -- Create a new unnamed buffer
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim._buffers[bufnr].name = ""
      vim._buffers[bufnr].options = vim._buffers[bufnr].options or {}
      vim._buffers[bufnr].options.modified = false
      vim._buffers[bufnr].lines = { "" }

      -- Create a new window for this tab
      local winid = vim._next_winid
      vim._next_winid = vim._next_winid + 1
      vim._windows[winid] = { buf = bufnr, width = 80 }
      vim._win_tab[winid] = new_tab
      vim._tab_windows[new_tab] = { winid }
      vim._current_window = winid
    elseif command:match("vsplit") then
      -- Split current window vertically; new window shows same buffer
      local cur = vim._current_window
      local curtab = vim._current_tabpage
      local bufnr = vim._windows[cur] and vim._windows[cur].buf or 1
      local winid = vim._next_winid
      vim._next_winid = vim._next_winid + 1
      vim._windows[winid] = { buf = bufnr, width = 80 }
      vim._win_tab[winid] = curtab
      local list = vim._tab_windows[curtab] or {}
      table.insert(list, winid)
      vim._tab_windows[curtab] = list
      vim._current_window = winid
    elseif command:match("[^%w]split$") or command == "split" then
      -- Horizontal split: model similarly by creating a new window entry
      local cur = vim._current_window
      local curtab = vim._current_tabpage
      local bufnr = vim._windows[cur] and vim._windows[cur].buf or 1
      local winid = vim._next_winid
      vim._next_winid = vim._next_winid + 1
      vim._windows[winid] = { buf = bufnr, width = 80 }
      vim._win_tab[winid] = curtab
      local list = vim._tab_windows[curtab] or {}
      table.insert(list, winid)
      vim._tab_windows[curtab] = list
      vim._current_window = winid
    elseif command:match("^edit ") then
      local path = command:sub(6)
      -- Remove surrounding quotes if any
      path = path:gsub("^'", ""):gsub("'$", "")
      -- Find or create buffer for this path
      local bufnr = -1
      for id, b in pairs(vim._buffers) do
        if b.name == path then
          bufnr = id
          break
        end
      end
      if bufnr == -1 then
        bufnr = vim.api.nvim_create_buf(true, false)
        vim._buffers[bufnr].name = path
        -- Try to read file content if exists
        local f = io.open(path, "r")
        if f then
          -- Only read if the handle supports :read (avoid tests that stub io.open for writing only)
          local ok_read = (type(f) == "userdata") or (type(f) == "table" and type(f.read) == "function")
          if ok_read then
            local content = f:read("*a") or ""
            if type(f.close) == "function" then
              pcall(f.close, f)
            end
            vim._buffers[bufnr].lines = {}
            for line in (content .. "\n"):gmatch("(.-)\n") do
              table.insert(vim._buffers[bufnr].lines, line)
            end
          else
            -- Gracefully ignore non-readable stubs
          end
        end
      end
      vim.api.nvim_win_set_buf(vim._current_window, bufnr)
    elseif command:match("^tabclose") then
      -- Close current tab: remove all its windows and switch to the lowest-numbered remaining tab
      local curtab = vim._current_tabpage
      local wins = vim._tab_windows[curtab] or {}
      for _, w in ipairs(wins) do
        if vim._windows[w] then
          vim.api.nvim_win_close(w, true)
        end
      end
      vim._tab_windows[curtab] = nil
      vim._tabs[curtab] = nil
      -- switch to lowest-numbered existing tab
      local new_cur = nil
      for t, _ in pairs(vim._tabs) do
        if not new_cur or t < new_cur then
          new_cur = t
        end
      end
      if not new_cur then
        -- recreate a default tab and window
        vim._tabs[1] = true
        local bufnr = vim.api.nvim_create_buf(true, false)
        vim._buffers[bufnr].name = "/home/user/project/test.lua"
        local winid = vim._next_winid
        vim._next_winid = vim._next_winid + 1
        vim._windows[winid] = { buf = bufnr, width = 80 }
        vim._win_tab[winid] = 1
        vim._tab_windows[1] = { winid }
        vim._current_window = winid
        vim._current_tabpage = 1
      else
        vim._current_tabpage = new_cur
        local list = vim._tab_windows[new_cur]
        if list and #list > 0 then
          vim._current_window = list[1]
        end
      end
    else
      -- other commands (wincmd etc.) are recorded but not simulated
    end
  end,

  json = {
    encode = function(data)
      -- Extremely simplified JSON encoding, sufficient for basic test cases.
      -- Does not handle all JSON types or edge cases.
      if type(data) == "table" then
        local parts = {}
        for k, v in pairs(data) do
          local val
          if type(v) == "string" then
            val = '"' .. v .. '"'
          elseif type(v) == "table" then
            val = vim.json.encode(v)
          else
            val = tostring(v)
          end

          if type(k) == "number" then
            table.insert(parts, val)
          else
            table.insert(parts, '"' .. k .. '":' .. val)
          end
        end

        if #parts > 0 and type(next(data)) == "number" then
          return "[" .. table.concat(parts, ",") .. "]"
        else
          return "{" .. table.concat(parts, ",") .. "}"
        end
      elseif type(data) == "string" then
        return '"' .. data .. '"'
      else
        return tostring(data)
      end
    end,

    decode = function(json_str)
      -- This is a non-functional stub for `vim.json.decode`.
      -- If tests require actual JSON decoding, a proper library or a more
      -- sophisticated mock implementation would be necessary.
      return {}
    end,
  },

  -- Additional missing vim functions
  wait = function(timeout, condition, interval, fast_only)
    -- Optimized mock implementation for faster test execution
    local start_time = os.clock()
    interval = interval or 10 -- Reduced from 200ms to 10ms for faster polling
    timeout = timeout or 1000

    while (os.clock() - start_time) * 1000 < timeout do
      if condition and condition() then
        return true
      end
      -- Add a small sleep to prevent busy-waiting and reduce CPU usage
      os.execute("sleep 0.001") -- 1ms sleep
    end

    return false
  end,

  keymap = {
    set = function(mode, lhs, rhs, opts)
      -- Mock keymap setting
      vim._keymaps = vim._keymaps or {}
      vim._keymaps[mode] = vim._keymaps[mode] or {}
      vim._keymaps[mode][lhs] = { rhs = rhs, opts = opts }
    end,
  },

  split = function(str, sep)
    local result = {}
    local pattern = "([^" .. sep .. "]+)"
    for match in str:gmatch(pattern) do
      table.insert(result, match)
    end
    return result
  end,

  -- Add tbl_extend function for compatibility
  tbl_extend = function(behavior, ...)
    local tables = { ... }
    local result = {}

    for _, tbl in ipairs(tables) do
      for k, v in pairs(tbl) do
        if behavior == "force" or result[k] == nil then
          result[k] = v
        end
      end
    end

    return result
  end,

  g = setmetatable({}, {
    __index = function(_, key)
      return vim._vars[key]
    end,
    __newindex = function(_, key, value)
      vim._vars[key] = value
    end,
  }),

  b = setmetatable({}, {
    __index = function(_, bufnr)
      -- Return buffer-local variables for the given buffer
      if vim._buffers[bufnr] then
        if not vim._buffers[bufnr].b_vars then
          vim._buffers[bufnr].b_vars = {}
        end
        return vim._buffers[bufnr].b_vars
      end
      return {}
    end,
    __newindex = function(_, bufnr, vars)
      -- Set buffer-local variables for the given buffer
      if vim._buffers[bufnr] then
        vim._buffers[bufnr].b_vars = vars
      end
    end,
  }),

  deepcopy = function(tbl)
    if type(tbl) ~= "table" then
      return tbl
    end

    local copy = {}
    for k, v in pairs(tbl) do
      if type(v) == "table" then
        copy[k] = vim.deepcopy(v)
      else
        copy[k] = v
      end
    end

    return copy
  end,

  tbl_deep_extend = function(behavior, ...)
    local result = {}
    local tables = { ... }

    for _, tbl in ipairs(tables) do
      for k, v in pairs(tbl) do
        if type(v) == "table" and type(result[k]) == "table" then
          result[k] = vim.tbl_deep_extend(behavior, result[k], v)
        else
          result[k] = v
        end
      end
    end

    return result
  end,

  inspect = function(obj) -- Keep the mock inspect for controlled output
    if type(obj) == "string" then
      return '"' .. obj .. '"'
    elseif type(obj) == "table" then
      local items = {}
      local is_array = true
      local i = 1
      for k, _ in pairs(obj) do
        if k ~= i then
          is_array = false
          break
        end
        i = i + 1
      end

      if is_array then
        for _, v_arr in ipairs(obj) do
          table.insert(items, vim.inspect(v_arr))
        end
        return "{" .. table.concat(items, ", ") .. "}" -- Lua tables are 1-indexed, show as {el1, el2}
      else -- map-like table
        for k_map, v_map in pairs(obj) do
          local key_str
          if type(k_map) == "string" then
            key_str = k_map
          else
            key_str = "[" .. vim.inspect(k_map) .. "]"
          end
          table.insert(items, key_str .. " = " .. vim.inspect(v_map))
        end
        return "{" .. table.concat(items, ", ") .. "}"
      end
    elseif type(obj) == "boolean" then
      return tostring(obj)
    elseif type(obj) == "number" then
      return tostring(obj)
    elseif obj == nil then
      return "nil"
    else
      return type(obj) .. ": " .. tostring(obj) -- Fallback for other types
    end
  end,

  --- Stub for the `vim.loop` module.
  --- Provides minimal implementations for TCP and timer functionalities
  --- required by some plugin tests.
  loop = {
    new_tcp = function()
      return {
        bind = function(self, host, port)
          return true
        end,
        listen = function(self, backlog, callback)
          return true
        end,
        accept = function(self, client)
          return true
        end,
        read_start = function(self, callback)
          return true
        end,
        write = function(self, data, callback)
          if callback then
            callback()
          end
          return true
        end,
        close = function(self)
          return true
        end,
        is_closing = function(self)
          return false
        end,
      }
    end,
    new_timer = function()
      return {
        start = function(self, timeout, repeat_interval, callback)
          return true
        end,
        stop = function(self)
          return true
        end,
        close = function(self)
          return true
        end,
      }
    end,
    now = function()
      return os.time() * 1000
    end,
    timer_stop = function(timer)
      return true
    end,
  },

  schedule = function(callback)
    callback()
  end,

  defer_fn = function(fn, timeout)
    -- For testing purposes, this mock executes the deferred function immediately
    -- instead of after a timeout.
    fn()
  end,

  notify = function(msg, level, opts)
    -- Store the last notification for test assertions.
    vim._last_notify = {
      msg = msg,
      level = level,
      opts = opts,
    }
    -- Return a mock notification ID, as some code might expect a return value.
    return 1
  end,

  log = {
    levels = {
      TRACE = 0,
      DEBUG = 1,
      ERROR = 2,
      WARN = 3,
      INFO = 4,
    },
    -- Provides log level constants, similar to `vim.log.levels`.
    -- The actual logging functions (trace, debug, etc.) are no-ops in this mock.
    -- These are primarily for `vim.notify` level compatibility if used.
    trace = function(...) end,
    debug = function(...) end,
    info = function(...) end,
    warn = function(...) end,
    error = function(...) end,
  },
}

-- Helper function to split lines
local function split_lines(str)
  local lines = {}
  for line in str:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end
  return lines
end

--- Internal helper functions for tests to manipulate the mock's state.
--- These are not part of the Neovim API but are useful for setting up
--- specific scenarios for testing plugins.
vim._mock = {
  add_buffer = function(bufnr, name, content, opts)
    vim._buffers[bufnr] = {
      name = name,
      lines = type(content) == "string" and split_lines(content) or content,
      options = opts or {},
      listed = true,
    }
  end,

  split_lines = split_lines,

  add_window = function(winid, bufnr, cursor)
    vim._windows[winid] = {
      buf = bufnr,
      cursor = cursor or { 1, 0 },
      width = 80,
    }
  end,

  reset = function()
    vim._buffers = {}
    vim._windows = {}
    vim._win_tab = {}
    vim._tab_windows = {}
    vim._next_winid = 1000
    vim._commands = {}
    vim._autocmds = {}
    vim._vars = {}
    vim._options = {}
    vim._last_command = nil
    vim._last_echo = nil
    vim._last_error = nil
  end,
}

if _G.vim == nil then
  _G.vim = vim
end
vim._mock.add_buffer(1, "/home/user/project/test.lua", "local test = {}\nreturn test")
vim._mock.add_window(1000, 1, { 1, 0 })
vim._win_tab[1000] = 1
vim._tab_windows[1] = { 1000 }
vim._current_window = 1000

-- Global options table (minimal)
vim.o = setmetatable({ columns = 120, lines = 40 }, {
  __index = function(_, k)
    return vim._options[k]
  end,
  __newindex = function(_, k, v)
    vim._options[k] = v
  end,
})

return vim
