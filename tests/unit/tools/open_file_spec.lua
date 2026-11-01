require("tests.busted_setup") -- Ensure test helpers are loaded

describe("Tool: open_file", function()
  local open_file_handler
  local buffer_lines
  local marks
  local coladds
  local original_buf_is_loaded
  local edit_buffers
  local cursor
  local editor_mode
  local gv_mode
  local original_get_mode
  local typed_over_selection
  local call_win
  local last_visual
  local operated_on
  local typeahead
  local original_feedkeys
  local original_replace_termcodes
  local state_flags
  local original_state, original_exists

  before_each(function()
    -- Mock Neovim functions used by the handler
    _G.vim = _G.vim or {}
    _G.vim.fn = _G.vim.fn or {}
    _G.vim.api = _G.vim.api or {}
    _G.vim.cmd_history = {} -- Store cmd history for assertions
    _G.vim.fn.expand = spy.new(function(path)
      return path -- Simple pass-through for testing
    end)
    _G.vim.fn.filereadable = spy.new(function(path)
      if path == "non_readable_file.txt" then
        return 0
      end
      return 1 -- Assume readable by default for other paths
    end)
    _G.vim.fn.fnameescape = spy.new(function(path)
      return path -- Simple pass-through
    end)
    -- Like Neovim, gv reselects in the buffer's last Visual mode (v, V or CTRL-V), as Select mode when 'selectmode'
    -- has "cmd" (gv_mode "s"). <Esc> ends Visual or Select mode, and so does :edit in the current window. In Select
    -- mode any other typed key replaces the selected text. A pending operator (mode "no") acts on what gv selects.
    editor_mode = "n"
    gv_mode = "v"
    last_visual = "v"
    typed_over_selection = {}
    operated_on = {}
    call_win = nil
    local kind_of = { v = "v", s = "v", V = "V", S = "V", ["\22"] = "\22", ["\19"] = "\22" }
    local select_of = { v = "s", V = "S", ["\22"] = "\19" }
    _G.vim.cmd = spy.new(function(command)
      table.insert(_G.vim.cmd_history, command)
      local keys = command:match("^normal! (.*)")
      local in_visual = kind_of[editor_mode] ~= nil
      if keys and keys ~= "\27" and editor_mode:match("^[sS\19]") then
        table.insert(typed_over_selection, keys)
        editor_mode = "n"
      elseif keys == "gv" and editor_mode:match("^no") then
        table.insert(operated_on, "gv")
        editor_mode = "n"
      elseif keys == "gv" then
        editor_mode = gv_mode == "s" and select_of[last_visual] or last_visual
      elseif command == "noautocmd normal! v\27" and editor_mode == "n" then
        last_visual = "v"
      elseif in_visual and (keys == "\27" or (command:match("^p?edit ") and (call_win == nil or call_win == 1000))) then
        last_visual = kind_of[editor_mode]
        editor_mode = "n"
      end
    end)
    -- Like Neovim, keys fed with the "i" flag go before keys the user types next. A pending operator takes the
    -- next key as its motion and acts from where the user typed the operator, unless that key is <Esc>.
    typeahead = {}
    original_feedkeys = _G.vim.api.nvim_feedkeys
    original_replace_termcodes = _G.vim.api.nvim_replace_termcodes
    _G.vim.api.nvim_replace_termcodes = spy.new(function(str)
      return (str:gsub("<Esc>", "\27"))
    end)
    _G.vim.api.nvim_feedkeys = spy.new(function(keys, flags, escape_ks)
      table.insert(typeahead, flags:find("i", 1, true) and 1 or #typeahead + 1, keys)
    end)
    original_get_mode = _G.vim.api.nvim_get_mode
    _G.vim.api.nvim_get_mode = spy.new(function()
      return { mode = editor_mode, blocking = false }
    end)

    -- Mock vim.json.encode
    _G.vim.json = _G.vim.json or {}
    _G.vim.json.encode = spy.new(function(data, opts)
      return require("tests.busted_setup").json_encode(data)
    end)

    -- Mock window-related APIs
    _G.vim.api.nvim_list_wins = spy.new(function()
      return { 1000 } -- Return a single window
    end)
    _G.vim.api.nvim_win_get_buf = spy.new(function(win)
      return 1 -- Mock buffer ID
    end)
    _G.vim.api.nvim_buf_get_option = spy.new(function(buf, option)
      return "" -- Return empty string for all options
    end)
    _G.vim.api.nvim_win_get_config = spy.new(function(win)
      return {} -- Return empty config (no relative positioning)
    end)
    _G.vim.api.nvim_win_get_option = spy.new(function(win, option)
      return false -- No window is in diff mode by default
    end)
    _G.vim.api.nvim_win_call = spy.new(function(win, callback)
      local outer = call_win
      call_win = win
      local result = callback()
      call_win = outer
      return result
    end)
    _G.vim.api.nvim_set_current_win = spy.new(function(win)
      -- Do nothing
    end)
    _G.vim.api.nvim_get_current_win = spy.new(function()
      return 1000
    end)
    _G.vim.api.nvim_get_current_buf = spy.new(function()
      return 1 -- Mock current buffer ID
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function(buf)
      return "test.txt" -- Mock buffer name
    end)
    _G.vim.api.nvim_buf_line_count = spy.new(function(buf)
      return #buffer_lines
    end)
    buffer_lines = {
      "local function test()",
      "  print('hello')",
      "  return true",
      "end",
    }
    marks = {}
    coladds = {}
    -- Like Neovim, marks and the cursor take a 1-based row and a 0-based column. Like Neovim 0.8,
    -- nvim_buf_set_mark also sets the mark's coladd to the column.
    _G.vim.api.nvim_buf_set_mark = spy.new(function(buf, name, line, col, opts)
      if line > #buffer_lines then
        error("Invalid 'line': out of range")
      end
      marks[name] = { line, col }
      coladds[name] = col
      return true
    end)
    _G.vim.fn.setpos = spy.new(function(expr, pos)
      if pos[2] < 1 or pos[2] > #buffer_lines then
        return -1
      end
      marks[expr:sub(2)] = { pos[2], pos[3] - 1 }
      coladds[expr:sub(2)] = pos[4]
      return 0
    end)
    original_buf_is_loaded = _G.vim.api.nvim_buf_is_loaded
    _G.vim.api.nvim_buf_is_loaded = spy.new(function(buf)
      return true
    end)
    -- bufexists() and bufadd() find the buffer that :edit would reuse for a path, by name or cached inode.
    edit_buffers = {}
    _G.vim.fn.bufexists = spy.new(function(path)
      return edit_buffers[path] and 1 or 0
    end)
    _G.vim.fn.bufadd = spy.new(function(path)
      return assert(edit_buffers[path], "bufadd would create a buffer for " .. path)
    end)
    _G.vim.fn.readfile = spy.new(function(path, flags, max)
      local read = {}
      for line_nr = 1, math.min(max or #buffer_lines, #buffer_lines) do
        read[line_nr] = buffer_lines[line_nr]
      end
      return read
    end)
    _G.vim.api.nvim_buf_get_lines = spy.new(function(buf, start, end_line, strict)
      if end_line < 0 then
        end_line = #buffer_lines + end_line + 1
      end
      local slice = {}
      for line_nr = start + 1, math.min(end_line, #buffer_lines) do
        slice[#slice + 1] = buffer_lines[line_nr]
      end
      return slice
    end)
    cursor = nil
    _G.vim.api.nvim_win_set_cursor = spy.new(function(win, pos)
      if pos[1] < 1 or pos[1] > #buffer_lines then
        error("Invalid cursor line: out of range")
      end
      cursor = { pos[1], pos[2] }
    end)
    _G.vim.o = _G.vim.o or {}
    _G.vim.o.selection, _G.vim.o.eventignore = "inclusive", ""
    _G.vim.fn.getcmdwintype = spy.new(function()
      return ""
    end)
    -- Like Neovim 0.10+, state() has "S" while CTRL-O from Insert mode waits to return there (and in Terminal mode).
    state_flags = ""
    original_state, original_exists = _G.vim.fn.state, _G.vim.fn.exists
    _G.vim.fn.state = spy.new(function()
      return state_flags
    end)
    _G.vim.fn.exists = spy.new(function(name)
      return name == "*state" and 1 or 0
    end)

    -- The module reads the loaded buffers when it loads, so it loads after the mocks.
    package.loaded["claudecode.tools.open_file"] = nil
    open_file_handler = require("claudecode.tools.open_file").handler
  end)

  after_each(function()
    -- Clean up global mocks if necessary, though spy.restore() is better if using full spy.lua
    _G.vim.fn.expand = nil
    _G.vim.fn.filereadable = nil
    _G.vim.fn.fnameescape = nil
    _G.vim.cmd = nil
    _G.vim.cmd_history = nil
    _G.vim.fn.setpos = nil
    _G.vim.fn.readfile = nil
    _G.vim.fn.bufexists = nil
    _G.vim.fn.bufadd = nil
    _G.vim.fn.getcmdwintype = nil
    _G.vim.fn.state, _G.vim.fn.exists = original_state, original_exists
    _G.vim.api.nvim_buf_is_loaded = original_buf_is_loaded
    _G.vim.api.nvim_get_mode = original_get_mode
    _G.vim.api.nvim_feedkeys = original_feedkeys
    _G.vim.api.nvim_replace_termcodes = original_replace_termcodes
    _G.vim.o.selection, _G.vim.o.eventignore = nil, nil
  end)

  it("should error if filePath parameter is missing", function()
    local success, err = pcall(open_file_handler, {})
    expect(success).to_be_false()
    expect(err).to_be_table()
    expect(err.code).to_be(-32602) -- Invalid params
    assert_contains(err.message, "Invalid params")
    assert_contains(err.data, "Missing filePath parameter")
  end)

  it("should error if file is not readable", function()
    local params = { filePath = "non_readable_file.txt" }
    local success, err = pcall(open_file_handler, params)
    expect(success).to_be_false()
    expect(err).to_be_table()
    expect(err.code).to_be(-32000) -- File operation error
    assert_contains(err.message, "File operation error")
    assert_contains(err.data, "File not found: non_readable_file.txt")
    assert.spy(_G.vim.fn.filereadable).was_called_with("non_readable_file.txt")
  end)

  it("should call vim.cmd with edit and the escaped file path on success", function()
    local params = { filePath = "readable_file.txt" }
    local success, result = pcall(open_file_handler, params)

    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")
    expect(result.content[1].text).to_be("Opened file: readable_file.txt")

    assert.spy(_G.vim.fn.filereadable).was_called_with("readable_file.txt")
    assert.spy(_G.vim.fn.fnameescape).was_called_with("readable_file.txt")

    expect(#_G.vim.cmd_history).to_be(1)
    expect(_G.vim.cmd_history[1]).to_be("edit readable_file.txt")
  end)

  it("should expand a leading tilde to $HOME", function()
    local home = os.getenv("HOME")
    local expanded = home .. "/.config/nvim/init.lua"
    local params = { filePath = "~/.config/nvim/init.lua" }
    local success, result = pcall(open_file_handler, params)

    expect(success).to_be_true()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")
    expect(result.content[1].text).to_be("Opened file: " .. expanded)
    assert.spy(_G.vim.fn.filereadable).was_called_with(expanded)
    assert.spy(_G.vim.fn.fnameescape).was_called_with(expanded)
    expect(_G.vim.cmd_history[1]).to_be("edit " .. expanded)
  end)

  it("should preserve a literal $ in the path (e.g. TanStack $param files)", function()
    -- Regression: vim.fn.expand treated `$post` as an undefined env var and
    -- stripped it; expand_tilde leaves it intact so the file is found.
    local params = { filePath = "src/routes/$post.tsx" }
    local success, result = pcall(open_file_handler, params)

    expect(success).to_be_true()
    expect(result.content[1].text).to_be("Opened file: src/routes/$post.tsx")
    assert.spy(_G.vim.fn.filereadable).was_called_with("src/routes/$post.tsx")
    expect(_G.vim.cmd_history[1]).to_be("edit src/routes/$post.tsx")
  end)

  it("should handle makeFrontmost=false to return detailed JSON", function()
    local params = { filePath = "test.txt", makeFrontmost = false }
    local success, result = pcall(open_file_handler, params)

    expect(success).to_be_true()
    expect(result.content).to_be_table()
    expect(result.content[1].type).to_be("text")

    -- makeFrontmost=false should return JSON-encoded detailed info
    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.success).to_be_true()
    expect(parsed_result.filePath).to_be("test.txt")
  end)

  it("should ignore empty startText and endText from Claude Code", function()
    local params = { filePath = "test.txt", makeFrontmost = false, startText = "", endText = "" }
    local success, result = pcall(open_file_handler, params)

    expect(success).to_be_true()
    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.success).to_be_true()
    expect(parsed_result.filePath).to_be("test.txt")
    expect(#_G.vim.cmd_history).to_be(1)
    expect(_G.vim.cmd_history[1]).to_be("edit test.txt")
  end)

  it("should report details from the background target window", function()
    _G.vim.api.nvim_list_wins = spy.new(function()
      return { 2000 }
    end)
    _G.vim.api.nvim_win_get_buf = spy.new(function(win)
      if win == 2000 then
        return 20
      end
      return 99
    end)
    _G.vim.api.nvim_get_current_buf = spy.new(function()
      return 99
    end)
    _G.vim.api.nvim_buf_get_option = spy.new(function(buf, option)
      if option == "buftype" then
        return ""
      end
      if option == "filetype" then
        return buf == 20 and "lua" or "wrong"
      end
      return ""
    end)
    _G.vim.api.nvim_buf_line_count = spy.new(function(buf)
      return buf == 20 and 42 or 1
    end)

    local params = { filePath = "test.txt", makeFrontmost = false }
    local success, result = pcall(open_file_handler, params)

    expect(success).to_be_true()
    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.languageId).to_be("lua")
    expect(parsed_result.lineCount).to_be(42)
    assert.spy(_G.vim.api.nvim_set_current_win).was_not_called()
  end)

  it("does not open into a diff-mode window; picks the plain editor (issue #277)", function()
    -- Window 1000 is in diff mode (a user's vimdiff/diffview pane); window 2000
    -- is a plain editor. openFile must :edit into 2000, never 1000 -- :edit-ing
    -- into a diff window clears its 'diff' and breaks the user's review.
    _G.vim.api.nvim_list_wins = spy.new(function()
      return { 1000, 2000 }
    end)
    _G.vim.api.nvim_win_get_buf = spy.new(function(win)
      return win == 1000 and 10 or 20
    end)
    _G.vim.api.nvim_buf_get_option = spy.new(function(buf, option)
      return "" -- plain buffers in both windows
    end)
    _G.vim.api.nvim_win_get_option = spy.new(function(win, option)
      if option == "diff" then
        return win == 1000 -- only the first window is in diff mode
      end
      return false
    end)
    local called_win
    _G.vim.api.nvim_win_call = spy.new(function(win, callback)
      called_win = win
      return callback()
    end)

    local params = { filePath = "test.txt" }
    local success = pcall(open_file_handler, params)

    expect(success).to_be_true()
    expect(called_win).to_be(2000)
    expect(_G.vim.cmd_history[1]).to_be("edit test.txt")
  end)

  it("does not open into the preview window, which nvim_list_wins lists first after :pedit", function()
    _G.vim.api.nvim_list_wins = spy.new(function()
      return { 1000, 2000 }
    end)
    _G.vim.api.nvim_win_get_option = spy.new(function(win, option)
      return option == "previewwindow" and win == 1000
    end)
    local called_win
    _G.vim.api.nvim_win_call = spy.new(function(win, callback)
      called_win = win
      return callback()
    end)

    expect(pcall(open_file_handler, { filePath = "test.txt" })).to_be_true()
    expect(called_win).to_be(2000)
    expect(_G.vim.cmd_history[1]).to_be("edit test.txt")
  end)

  describe("with no suitable editor window", function()
    -- Like Neovim, wincmd t and l move to the top-left window and to its right, wincmd j to the window below, and
    -- vsplit and {N}split make a new current window next to or above the current one, showing the same buffer.
    local order, windows, current, edited_in

    local function layout(list)
      order, windows, current, edited_in = {}, {}, list[#list].id, nil
      for i, w in ipairs(list) do
        order[i], windows[w.id] = w.id, w
      end
    end

    before_each(function()
      local run_cmd = _G.vim.cmd
      _G.vim.cmd = spy.new(function(command)
        local at
        for i, id in ipairs(order) do
          if id == current then
            at = i
          end
        end
        if command == "wincmd t" then
          current = order[1]
        elseif command == "wincmd j" then
          current = order[at + 1] or current
        elseif command == "vsplit" then
          local id = 4000 + #order
          table.insert(order, at + 1, id)
          windows[id] = { id = id, buf = windows[current].buf, split_from = current }
          current = id
        elseif command == "12split" then
          local from, id = call_win or current, 4000 + #order
          for i, win in ipairs(order) do
            if win == from then
              table.insert(order, i, id)
              break
            end
          end
          windows[id] = { id = id, buf = windows[from].buf, split_from = from }
          if call_win then
            call_win = id
          else
            current = id
          end
        elseif command:match("^edit ") then
          edited_in = call_win or current
        end
        run_cmd(command)
      end)
      _G.vim.api.nvim_list_wins = spy.new(function()
        return order
      end)
      _G.vim.api.nvim_get_current_win = spy.new(function()
        return call_win or current
      end)
      _G.vim.api.nvim_set_current_win = spy.new(function(win)
        current = win
      end)
      _G.vim.api.nvim_win_get_buf = spy.new(function(win)
        return windows[win].buf
      end)
      _G.vim.api.nvim_buf_get_option = spy.new(function(buf, option)
        return option == "buftype" and buf == 10 and "terminal" or ""
      end)
      _G.vim.api.nvim_win_get_option = spy.new(function(win, option)
        return option == "previewwindow" and windows[win == 0 and (call_win or current) or win].preview == true
      end)
      _G.vim.api.nvim_win_set_option = spy.new(function(win, option, value)
        if option == "previewwindow" then
          windows[win].preview = value
        end
      end)
      _G.vim.api.nvim_win_set_buf = spy.new(function(win, buf)
        windows[win].buf = buf
      end)
      _G.vim.api.nvim_win_is_valid = spy.new(function(win)
        return windows[win] ~= nil
      end)
      _G.vim.api.nvim_win_get_tabpage = spy.new(function(win)
        return 1
      end)
      _G.vim.api.nvim_tabpage_list_wins = spy.new(function(tab)
        return order
      end)
      _G.vim.api.nvim_buf_set_option = spy.new(function() end)
      edit_buffers["test.txt"] = 50
      _G.vim.o.previewheight = 12
    end)

    after_each(function()
      _G.vim.o.previewheight = nil
    end)

    it("edits into a split of the preview window when it is the only window", function()
      layout({ { id = 3000, buf = 30, preview = true } })
      expect(pcall(open_file_handler, { filePath = "test.txt" })).to_be_true()
      expect(windows[edited_in].split_from).to_be(3000)
    end)

    it("splits the terminal, not the small preview window above it", function()
      layout({ { id = 3000, buf = 30, preview = true }, { id = 1000, buf = 10 } })
      expect(pcall(open_file_handler, { filePath = "test.txt" })).to_be_true()
      expect(windows[edited_in].split_from).to_be(1000)
    end)

    it("keeps the focus with makeFrontmost = false and moves it to the file otherwise", function()
      layout({ { id = 1000, buf = 10 } })
      expect(pcall(open_file_handler, { filePath = "test.txt", makeFrontmost = false })).to_be_true()
      expect(windows[edited_in].split_from).to_be(1000)
      expect(current).to_be(1000)

      layout({ { id = 1000, buf = 10 } })
      expect(pcall(open_file_handler, { filePath = "test.txt" })).to_be_true()
      expect(current).to_be(edited_in)
    end)

    for _, case in ipairs({
      {
        name = "the preview window and a terminal",
        list = { { id = 3000, buf = 20, preview = true }, { id = 1000, buf = 10 } },
      },
      { name = "only a terminal", list = { { id = 1000, buf = 10 } } },
    }) do
      it("shows a preview in the preview window and leaves one window on the terminal, with " .. case.name, function()
        layout(case.list)
        expect(pcall(open_file_handler, { filePath = "test.txt", preview = true })).to_be_true()
        local on_terminal, previews = {}, {}
        for _, id in ipairs(order) do
          if windows[id].buf == 10 then
            on_terminal[#on_terminal + 1] = id
          end
          if windows[id].preview then
            previews[#previews + 1] = windows[id].buf
          end
        end
        assert.are.same({ { 1000 }, { 50 } }, { on_terminal, previews })
      end)
    end
  end)

  it("splits instead of editing into a diff window when every window is a diff (issue #277)", function()
    -- All windows are in diff mode, so the finder returns nil and the fallback
    -- runs. It must create a split rather than :edit over a diff window.
    _G.vim.api.nvim_list_wins = spy.new(function()
      return { 1000 }
    end)
    _G.vim.api.nvim_win_get_option = spy.new(function(win, option)
      if option == "diff" then
        return true
      end
      return false
    end)

    local params = { filePath = "test.txt" }
    local success = pcall(open_file_handler, params)

    expect(success).to_be_true()
    -- The fallback issues a vsplit and then clears diff on the new split (so the
    -- opened file never joins the user's diff set), both before the edit.
    local saw_vsplit, saw_diffoff, saw_edit = false, false, false
    local vsplit_idx, edit_idx = nil, nil
    for i, cmd in ipairs(_G.vim.cmd_history) do
      if cmd == "vsplit" then
        saw_vsplit = true
        vsplit_idx = i
      elseif cmd == "diffoff" then
        saw_diffoff = true
      elseif cmd == "edit test.txt" then
        saw_edit = true
        edit_idx = i
      end
    end
    expect(saw_vsplit).to_be_true()
    expect(saw_diffoff).to_be_true()
    -- diffoff must precede the edit, and the edit must happen after the split.
    expect(saw_edit).to_be_true()
    expect(vsplit_idx < edit_idx).to_be_true()
  end)

  it("changes nothing while the command-line window is open", function()
    _G.vim.fn.getcmdwintype = spy.new(function()
      return ":"
    end)
    local success, err = pcall(open_file_handler, { filePath = "test.txt", startLine = 2 })
    expect(success).to_be_false()
    expect(err.code).to_be(-32000)
    assert.are.same({}, _G.vim.cmd_history)
  end)

  describe("with preview", function()
    -- Like Neovim, :pedit shows the file in the preview window (3000) and leaves the cursor in the current window,
    -- which keeps its own buffer (10), while :edit shows it in the current window. Both re-read the file when the
    -- window they edit in already shows it, which fails with E37 on unsaved changes, and both end Visual mode.
    -- {N}split, nvim_win_set_buf, bufadd and bufload do neither. Marks, the cursor and gv act in the current
    -- window, or in the window that nvim_win_call runs in. nvim_win_set_buf refuses a window with 'winfixbuf' set,
    -- which a split does not copy.
    -- A window that enters a loaded buffer and :checktime load the file again when it changed on disk (`disk`), the
    -- buffer has no unsaved changes and 'autoread' is set. Otherwise a FileChangedShell autocommand for the buffer
    -- decides with v:fcs_choice, unless 'eventignore' ignores it, or 'eventignorewin' (`ignore_win`) of the window
    -- that enters the buffer, of the current window when it shows the buffer, or else of every window that shows it.
    -- Without one Neovim asks the user, whose next key answers. :edit of another buffer checks it before it switches,
    -- so there 'eventignorewin' counts only when every window that shows the buffer ignores the event. Neovim checks
    -- no buffer whose 'buftype' is set. For a buffer opened before its file existed (`new_file`, which BufNewFile
    -- marks) it asks W13 once the file exists, without FileChangedShell. Deleting a deleted autocommand fails. :edit
    -- re-reads the buffer that its window shows without asking. A buffer loads, with its BufReadPost, FileType and
    -- BufEnter autocommands (`events`), in the window that enters it, or for bufload() in a hidden autocommand window.
    -- A failing BufReadPost autocommand (`read_error`) stops a read halfway under a command from Lua, and under
    -- :silent! the read ends and v:errmsg keeps the error. An autocommand can also set v:errmsg for an error it hides
    -- itself (`handled_error`). The file on disk stays readable after a read (`on_disk`).
    local current_win, win_buf, win_cursor, preview_flag, fixed_buf, buffers, mark_pos, visual, asked, events, autocmds
    local ignore_win, silenced, call_buf
    local original_win_get_tabpage, original_tabpage_list_wins, original_win_is_valid
    local original_create_autocmd, original_del_autocmd, original_v, original_buf_call, original_list_bufs

    local function fire(event, buf)
      for _, autocmd in pairs(autocmds) do
        local events_of = type(autocmd and autocmd.event) == "table" and autocmd.event or { autocmd and autocmd.event }
        for _, name in ipairs(events_of) do
          if name == event and (autocmd.buffer == nil or autocmd.buffer == buf) then
            autocmd.callback({ buf = buf, match = "test.txt" })
          end
        end
      end
    end

    local function buf_of(buf)
      return buf == 0 and win_buf[call_win or current_win] or buf
    end

    local function text_between(lines, from, to)
      local picked = {}
      for row = from[1], to[1] do
        local first = row == from[1] and from[2] + 1 or 1
        local last = row == to[1] and to[2] + 1 or #lines[row]
        picked[#picked + 1] = lines[row]:sub(first, last)
      end
      return table.concat(picked, "\n")
    end

    local function open(params)
      params.filePath = "test.txt"
      params.preview = true
      local success, result = pcall(open_file_handler, params)
      expect(success).to_be_true()
      return result.content[1].text
    end

    before_each(function()
      original_win_get_tabpage = _G.vim.api.nvim_win_get_tabpage
      original_tabpage_list_wins = _G.vim.api.nvim_tabpage_list_wins
      original_win_is_valid = _G.vim.api.nvim_win_is_valid
      original_create_autocmd, original_del_autocmd = _G.vim.api.nvim_create_autocmd, _G.vim.api.nvim_del_autocmd
      original_v, original_buf_call, original_list_bufs = _G.vim.v, _G.vim.api.nvim_buf_call, _G.vim.api.nvim_list_bufs
      buffer_lines = { "alpha", "beta", "gamma", "delta", "epsilon" }
      current_win, win_buf, win_cursor, preview_flag, fixed_buf, mark_pos, visual, ignore_win =
        1000, { [1000] = 10 }, {}, {}, {}, {}, nil, {}
      buffers = {
        [10] = { lines = { "one", "two", "three", "four" }, filetype = "text" },
        [30] = { lines = buffer_lines, filetype = "lua" },
      }
      _G.vim.o.previewheight, _G.vim.o.autoread, _G.vim.o.eventignore = 12, true, ""
      asked, events, autocmds = false, {}, {}
      _G.vim.v = {}
      _G.vim.api.nvim_create_autocmd = spy.new(function(event, opts)
        autocmds[#autocmds + 1] = { event = event, buffer = opts.buffer, callback = opts.callback }
        return #autocmds
      end)
      _G.vim.api.nvim_del_autocmd = spy.new(function(id)
        if not autocmds[id] then
          error("Failed to delete autocmd")
        end
        autocmds[id] = false
      end)
      local function read_disk(buf)
        local old = buffers[buf].lines
        local new = buffers[buf].disk or buffers[buf].on_disk or old
        buffers[buf].disk, buffers[buf].new_file, buffers[buf].on_disk = nil, nil, new
        fire("BufReadPre", buf)
        if buffers[buf].read_error and not silenced then
          buffers[buf].lines = { unpack(old) }
          table.insert(buffers[buf].lines, "")
          table.insert(buffers[buf].lines, "")
          error('BufReadPost Autocommands for "*": user boom')
        end
        buffers[buf].lines = new
        if buffers[buf].read_error then
          _G.vim.v.errmsg = "user boom"
        elseif buffers[buf].handled_error then
          _G.vim.v.errmsg = "E31: No such mapping" -- sil! nunmap <buffer> [[ in Neovim's markdown ftplugin
        end
        fire("BufReadPost", buf)
      end
      local function ignored_in(buf, entering_win, via_edit)
        if _G.vim.o.eventignore == "all" or _G.vim.o.eventignore == "FileChangedShell" then
          return true
        end
        local current = call_win or current_win
        local wins = {}
        if entering_win and not via_edit or win_buf[current] == buf then
          wins = { entering_win or current }
        else
          for win, shown in pairs(win_buf) do
            if shown == buf then
              wins[#wins + 1] = win
            end
          end
        end
        for _, win in ipairs(wins) do
          if ignore_win[win] ~= "FileChangedShell" then
            return false
          end
        end
        return #wins > 0
      end
      local function check_disk(buf, entering_win, via_edit)
        if not buffers[buf].disk or (buffers[buf].buftype or "") ~= "" then
          return
        elseif buffers[buf].new_file then
          asked = true -- W13
          return
        elseif _G.vim.o.autoread and not buffers[buf].modified then
          return read_disk(buf)
        end
        local handled = false
        local ignored = ignored_in(buf, entering_win, via_edit)
        _G.vim.v.fcs_reason, _G.vim.v.fcs_choice = buffers[buf].modified and "conflict" or "changed", ""
        for _, autocmd in pairs(autocmds) do
          if autocmd and autocmd.event == "FileChangedShell" and autocmd.buffer == buf and not ignored then
            handled = true
            autocmd.callback()
          end
        end
        if not handled or _G.vim.v.fcs_choice == "ask" then
          asked = true
        elseif _G.vim.v.fcs_choice == "reload" then
          read_disk(buf)
        end
      end
      local function enter(win, buf, where, via_edit)
        if not buffers[buf].loaded then
          buffers[buf].loaded = true
          read_disk(buf)
          events[#events + 1] = "load@" .. where
        elseif win_buf[win] ~= buf then
          check_disk(buf, win, via_edit)
        end
        win_buf[win] = buf
        events[#events + 1] = "enter@" .. where
      end
      local function edit_file_in(win)
        if win_buf[win] == 30 and buffers[30].modified then
          error("Vim(edit):E37: No write since last change (add ! to override)")
        elseif win_buf[win] == 30 then
          read_disk(30)
        else
          enter(win, 30, win, true)
        end
        if editor_mode:match("^[vVsS\22\19]") then
          editor_mode = "n"
        end
      end
      local run_cmd = _G.vim.cmd
      silenced = false
      _G.vim.cmd = spy.new(function(command)
        local recorded = command
        silenced = command:match("^silent! ") ~= nil
        command = command:gsub("^silent! ", "")
        local buftype = command:match("^noautocmd setlocal buftype=(.*)$")
        if buftype then
          buffers[call_buf].buftype = buftype
        elseif command == "edit" and call_buf then
          read_disk(call_buf)
        elseif command == "edit" and win_buf[call_win or current_win] ~= 30 then
          -- A bare :edit re-reads the buffer that its window shows. A 'nofile' buffer has no file, so it gets empty.
          local shown = buffers[win_buf[call_win or current_win]]
          if shown.buftype == "nofile" then
            shown.lines = { "" }
          end
        elseif command == "edit" then
          edit_file_in(call_win or current_win)
        elseif command:match("^pedit ") then
          if not win_buf[3000] then
            win_buf[3000], preview_flag[3000] = win_buf[call_win or current_win], true
          end
          edit_file_in(3000)
        elseif command:match("^edit ") then
          edit_file_in(call_win or current_win)
        elseif command:match("^checktime %d+$") then
          check_disk(tonumber(command:match("%d+")))
        elseif command == "12split" then
          win_buf[3000] = win_buf[call_win or current_win]
          call_win = 3000
        elseif command == "normal! gv" then
          local lines = buffers[buf_of(0)].lines
          visual = { win = call_win or current_win, text = text_between(lines, mark_pos["<"], mark_pos[">"]) }
        end
        silenced = false
        run_cmd(recorded)
      end)
      local win_call = _G.vim.api.nvim_win_call
      _G.vim.api.nvim_win_call = spy.new(function(win, callback)
        assert(win_buf[win] ~= nil, "Invalid window id: " .. tostring(win))
        return win_call(win, callback)
      end)
      _G.vim.api.nvim_buf_call = spy.new(function(buf, callback)
        local outer = call_buf
        call_buf = buf
        local result = callback()
        call_buf = outer
        return result
      end)
      _G.vim.fn.setpos = spy.new(function(expr, pos)
        mark_pos[expr:sub(2)] = { pos[2], pos[3] - 1 }
        return 0
      end)
      _G.vim.api.nvim_win_get_tabpage = spy.new(function(win)
        return 1
      end)
      _G.vim.api.nvim_tabpage_list_wins = spy.new(function(tab)
        return win_buf[3000] and { 1000, 3000 } or { 1000 }
      end)
      _G.vim.api.nvim_win_get_option = spy.new(function(win, option)
        win = win == 0 and (call_win or current_win) or win
        if option == "eventignorewin" then
          return ignore_win[win] or ""
        end
        return (option == "previewwindow" and preview_flag[win] or option == "winfixbuf" and fixed_buf[win]) == true
      end)
      _G.vim.api.nvim_win_set_option = spy.new(function(win, option, value)
        if option == "previewwindow" then
          preview_flag[win] = value
        elseif option == "winfixbuf" then
          fixed_buf[win] = value
        end
      end)
      _G.vim.api.nvim_win_set_buf = spy.new(function(win, buf)
        if fixed_buf[win] and win_buf[win] ~= buf then
          error("E1513: Cannot switch buffer. 'winfixbuf' is enabled")
        end
        if win_buf[win] ~= buf then
          enter(win, buf, win)
        end
      end)
      _G.vim.api.nvim_win_is_valid = spy.new(function(win)
        return win_buf[win] ~= nil
      end)
      _G.vim.fn.exists = spy.new(function(name)
        return (name == "*state" or name == "+winfixbuf" or name == "+eventignorewin") and 1 or 0
      end)
      _G.vim.fn.getbufvar = spy.new(function(buf, name)
        assert(name == "&autoread", name)
        return _G.vim.o.autoread and 1 or 0
      end)
      _G.vim.fn.win_findbuf = spy.new(function(buf)
        local wins = {}
        for win, shown in pairs(win_buf) do
          if shown == buf then
            wins[#wins + 1] = win
          end
        end
        table.sort(wins)
        return wins
      end)
      _G.vim.api.nvim_buf_set_option = spy.new(function() end)
      _G.vim.fn.bufexists = spy.new(function(path)
        return path == "test.txt" and buffers[30].loaded and 1 or 0
      end)
      _G.vim.fn.bufadd = spy.new(function(path)
        return 30
      end)
      _G.vim.fn.bufload = spy.new(function(buf)
        if not buffers[buf].loaded then
          buffers[buf].loaded = true
          read_disk(buf)
          events[#events + 1] = "load@autocmd window"
          events[#events + 1] = "enter@autocmd window"
        end
      end)
      _G.vim.api.nvim_buf_is_loaded = spy.new(function(buf)
        return buffers[buf].loaded == true
      end)
      _G.vim.api.nvim_win_set_cursor = spy.new(function(win, pos)
        win = win == 0 and (call_win or current_win) or win
        assert(pos[1] >= 1 and pos[1] <= #buffers[win_buf[win]].lines, "Invalid cursor line: out of range")
        win_cursor[win] = { pos[1], pos[2] }
      end)
      _G.vim.api.nvim_get_current_win = spy.new(function()
        return call_win or current_win
      end)
      _G.vim.api.nvim_set_current_win = spy.new(function(win)
        current_win = win
      end)
      _G.vim.api.nvim_win_get_buf = spy.new(function(win)
        return win_buf[win]
      end)
      _G.vim.api.nvim_get_current_buf = spy.new(function()
        return buf_of(0)
      end)
      _G.vim.api.nvim_buf_get_lines = spy.new(function(buf, start, end_line, strict)
        local lines = buffers[buf_of(buf)].lines
        return { unpack(lines, start + 1, end_line < 0 and #lines + end_line + 1 or end_line) }
      end)
      _G.vim.api.nvim_buf_line_count = spy.new(function(buf)
        return #buffers[buf_of(buf)].lines
      end)
      _G.vim.api.nvim_buf_get_option = spy.new(function(buf, option)
        if option == "modified" then
          return buffers[buf].modified == true
        elseif option == "buftype" then
          return buffers[buf].buftype or ""
        end
        return option == "filetype" and buffers[buf].filetype or ""
      end)
      _G.vim.api.nvim_buf_is_valid = spy.new(function(buf)
        return buffers[buf] ~= nil
      end)
      _G.vim.api.nvim_list_bufs = spy.new(function()
        return { 10, 30 }
      end)
      -- Load the module again, so that its BufNewFile, BufReadPost and BufWritePost autocommands are in `autocmds`.
      package.loaded["claudecode.tools.open_file"] = nil
      open_file_handler = require("claudecode.tools.open_file").handler
    end)

    after_each(function()
      _G.vim.api.nvim_win_get_tabpage = original_win_get_tabpage
      _G.vim.api.nvim_tabpage_list_wins = original_tabpage_list_wins
      _G.vim.api.nvim_win_is_valid = original_win_is_valid
      _G.vim.api.nvim_create_autocmd, _G.vim.api.nvim_del_autocmd = original_create_autocmd, original_del_autocmd
      _G.vim.v, _G.vim.api.nvim_buf_call, _G.vim.api.nvim_list_bufs = original_v, original_buf_call, original_list_bufs
      _G.vim.o.previewheight, _G.vim.o.autoread, _G.vim.o.eventignore = nil, nil, nil
      _G.vim.fn.win_findbuf, _G.vim.fn.getbufvar = nil, nil
    end)

    it("opens the file without a range", function()
      expect(open({})).to_be("Opened file: test.txt")
    end)

    it("selects lines in the preview window, which shows the file, and focuses it", function()
      expect(open({ startLine = 2, endLine = 3 })).to_be("Opened file and selected lines 2 to 3")
      assert.are.same({ win = 3000, text = "beta\ngamma" }, visual)
      expect(current_win).to_be(3000)
    end)

    it("finds startText and endText in the previewed file", function()
      expect(open({ startText = "beta", endText = "gamma" })).to_be(
        'Opened file and selected text from "beta" to "gamma"'
      )
      assert.are.same({ win = 3000, text = "beta\ngamma" }, visual)
      expect(current_win).to_be(3000)
    end)

    it("reports the previewed file and keeps the focus with makeFrontmost = false", function()
      local parsed = require("tests.busted_setup").json_decode(open({ makeFrontmost = false }))
      expect(parsed.languageId).to_be("lua")
      expect(parsed.lineCount).to_be(5)
      expect(current_win).to_be(1000)
    end)

    for _, case in ipairs({ { name = "a new preview window" }, { name = "the preview window", existing = true } }) do
      it("loads a file that is not loaded yet in " .. case.name .. ", which runs its autocommands once", function()
        if case.existing then
          win_buf[3000], preview_flag[3000] = 10, true
        end
        expect(open({ startLine = 2 })).to_be("Opened file and selected lines 2 to 2")
        assert.are.same({ "load@3000", "enter@3000" }, events)
      end)
    end

    it("shows the file in a preview window with 'winfixbuf' set and keeps the option, as :pedit does", function()
      win_buf[3000], preview_flag[3000], fixed_buf[3000] = 10, true, true
      expect(open({ startLine = 2 })).to_be("Opened file and selected lines 2 to 2")
      assert.are.same({ 30, true, true }, { win_buf[3000], preview_flag[3000], fixed_buf[3000] })
    end)

    it("fails when an autocommand clears 'previewwindow' as the window gets the file", function()
      local set_buf = _G.vim.api.nvim_win_set_buf
      _G.vim.api.nvim_win_set_buf = spy.new(function(win, buf)
        set_buf(win, buf)
        preview_flag[win] = false -- autocmd BufWinEnter * setlocal nopreviewwindow
      end)
      local success, err = pcall(open_file_handler, { filePath = "test.txt", preview = true, startLine = 2 })
      expect(success).to_be_false()
      assert.are.same(
        { code = -32000, message = "File operation error", data = "No preview window shows the file" },
        err
      )
    end)

    describe("when the file changed on disk", function()
      -- Claude can write the file before it asks to open it.
      before_each(function()
        buffers[30].loaded, buffers[30].disk = true, { "alpha", "beta", "fresh" }
        _G.vim.fn.readfile = spy.new(function(path, flags, max)
          local lines = buffers[30].disk or buffers[30].lines
          return { unpack(lines, 1, math.min(max or #lines, #lines)) }
        end)
      end)

      local grown = { "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta" }
      for _, case in ipairs({
        { name = "the window shows it", win = 1000 },
        { name = "the preview window shows it", win = 3000, preview = true },
        { name = "the buffer is hidden" },
      }) do
        it("accepts a startLine that only the grown file has when " .. case.name, function()
          buffers[30].disk = grown
          if case.win then
            win_buf[case.win], preview_flag[case.win] = 30, case.win == 3000 or nil
          end
          local success, result =
            pcall(open_file_handler, { filePath = "test.txt", preview = case.preview, startLine = 7 })
          expect(success).to_be_true()
          assert.are.same({ "Opened file and selected lines 7 to 7", "eta" }, { result.content[1].text, visual.text })
        end)
      end

      it("rejects a startLine that only the grown file has when the buffer keeps unsaved changes", function()
        buffers[30].disk, buffers[30].modified, win_buf[1000] = grown, true, 30
        local success, err = pcall(open_file_handler, { filePath = "test.txt", startLine = 7 })
        expect(success).to_be_false()
        expect(err.code).to_be(-32602)
      end)

      for _, autoread in ipairs({ true, false }) do
        for _, case in ipairs({
          { name = "the window shows it", main_win = true },
          { name = "the window shows it, with preview = true", main_win = true, preview = true },
          { name = "the preview window shows it", preview = true },
        }) do
          it(
            "loads the file again without asking when " .. case.name .. ", 'autoread' " .. tostring(autoread),
            function()
              _G.vim.o.autoread = autoread
              if case.main_win then
                win_buf[1000] = 30
              else
                win_buf[3000], preview_flag[3000] = 30, true
              end
              local success, result =
                pcall(open_file_handler, { filePath = "test.txt", preview = case.preview, startText = "fresh" })
              expect(success).to_be_true()
              expect(result.content[1].text).to_be('Opened file and selected text "fresh"')
              assert.are.same({ { "alpha", "beta", "fresh" }, false }, { buffers[30].lines, asked })
            end
          )
        end

        it("keeps unsaved changes and does not ask the user, 'autoread' " .. tostring(autoread), function()
          _G.vim.o.autoread = autoread
          win_buf[1000], buffers[30].modified = 30, true
          local success = pcall(open_file_handler, { filePath = "test.txt", preview = true, startLine = 2 })
          expect(success).to_be_true()
          assert.are.same({ { "alpha", "beta", "gamma", "delta", "epsilon" }, false }, { buffers[30].lines, asked })
        end)

        -- Entering a loaded buffer makes Neovim check its file, and the user's next key answers: `l` loads the file
        -- and drops the unsaved changes.
        for _, unsaved in ipairs({ false, true }) do
          for _, preview in ipairs({ false, true }) do
            it(
              ("never asks when it shows the hidden buffer%s %s unsaved changes, 'autoread' %s"):format(
                preview and " in the preview window" or "",
                unsaved and "with" or "without",
                tostring(autoread)
              ),
              function()
                _G.vim.o.autoread, buffers[30].modified = autoread, unsaved
                local success = pcall(open_file_handler, { filePath = "test.txt", preview = preview, startLine = 2 })
                expect(success).to_be_true()
                local lines = unsaved and { "alpha", "beta", "gamma", "delta", "epsilon" }
                  or { "alpha", "beta", "fresh" }
                assert.are.same({ lines, false }, { buffers[30].lines, asked })
              end
            )
          end
        end
      end

      it("does not check the file when 'eventignore' ignores FileChangedShell, so Neovim does not ask", function()
        _G.vim.o.autoread, _G.vim.o.eventignore, win_buf[1000] = false, "all", 30
        local success = pcall(open_file_handler, { filePath = "test.txt", startLine = 2 })
        expect(success).to_be_true()
        assert.are.same({ { "alpha", "beta", "gamma", "delta", "epsilon" }, false }, { buffers[30].lines, asked })
      end)

      it(
        "does not check the file when 'eventignorewin' of the current window that shows it ignores the event",
        function()
          _G.vim.o.autoread, win_buf[1000], ignore_win[1000] = false, 30, "FileChangedShell"
          local success = pcall(open_file_handler, { filePath = "test.txt", startLine = 2 })
          expect(success).to_be_true()
          assert.are.same({ { "alpha", "beta", "gamma", "delta", "epsilon" }, false }, { buffers[30].lines, asked })
        end
      )

      it("does not check the file when 'eventignorewin' of every window that shows it ignores the event", function()
        _G.vim.o.autoread, win_buf[3000], preview_flag[3000], ignore_win[3000] = false, 30, true, "FileChangedShell"
        local success = pcall(open_file_handler, { filePath = "test.txt", preview = true, startLine = 2 })
        expect(success).to_be_true()
        assert.are.same({ { "alpha", "beta", "gamma", "delta", "epsilon" }, false }, { buffers[30].lines, asked })
      end)

      for _, option in ipairs({ "eventignore", "eventignorewin" }) do
        it("loads the file again with 'autoread' when '" .. option .. "' ignores the event", function()
          win_buf[1000] = 30
          if option == "eventignore" then
            _G.vim.o.eventignore = "FileChangedShell"
          else
            ignore_win[1000] = "FileChangedShell"
          end
          local success = pcall(open_file_handler, { filePath = "test.txt", startLine = 2 })
          expect(success).to_be_true()
          assert.are.same({ { "alpha", "beta", "fresh" }, false }, { buffers[30].lines, asked })
        end)
      end

      it("loads the file again when another window that shows it does not ignore the event", function()
        _G.vim.o.autoread, win_buf[3000], preview_flag[3000], ignore_win[3000] = false, 30, true, "FileChangedShell"
        win_buf[2000] = 30 -- in another tab page
        local success = pcall(open_file_handler, { filePath = "test.txt", preview = true, startLine = 2 })
        expect(success).to_be_true()
        assert.are.same({ { "alpha", "beta", "fresh" }, false }, { buffers[30].lines, asked })
      end)

      it("answers when a user's FileChangedShell autocommand deletes openFile's", function()
        _G.vim.o.autoread, win_buf[1000] = false, 30
        _G.vim.api.nvim_create_autocmd("FileChangedShell", {
          buffer = 30,
          callback = function() -- autocmd! FileChangedShell
            for id, autocmd in pairs(autocmds) do
              if autocmd and autocmd.event == "FileChangedShell" then
                autocmds[id] = false
              end
            end
          end,
        })
        local success, result = pcall(open_file_handler, { filePath = "test.txt", startLine = 2 })
        expect(success).to_be_true()
        assert.are.same({ "Opened file and selected lines 2 to 2", false }, { result.content[1].text, asked })
      end)
    end)

    describe("when the buffer was opened before its file existed", function()
      -- Neovim fires BufNewFile for it. Claude then creates the file.
      before_each(function()
        buffers[30].loaded, buffers[30].lines, buffers[30].new_file = true, { "" }, true
        buffers[30].disk = { "from claude", "second" }
        fire("BufNewFile", 30)
      end)

      for _, case in ipairs({
        { name = "the window shows it", shown = 1000 },
        { name = "the preview window shows it", shown = 3000, preview = true },
        { name = "it is hidden" },
        { name = "it is hidden, with preview = true", preview = true },
        { name = "it is hidden, while the user types in another file", mode = "i" },
      }) do
        local function call()
          if case.shown then
            win_buf[case.shown], preview_flag[case.shown] = 30, case.shown == 3000 or nil
          end
          editor_mode = case.mode or "n"
          return pcall(open_file_handler, { filePath = "test.txt", preview = case.preview, startText = "second" })
        end

        it("never asks (W13) and loads the file when " .. case.name, function()
          local success, result = call()
          expect(success).to_be_true()
          assert_contains(result.content[1].text, '"second"')
          assert.are.same({ { "from claude", "second" }, false }, { buffers[30].lines, asked })
        end)

        it("never asks (W13) and keeps the unsaved text when " .. case.name, function()
          buffers[30].lines, buffers[30].modified = { "MY NOTES" }, true
          local success = call()
          expect(success).to_be_true()
          assert.are.same({ { "MY NOTES" }, false, "" }, { buffers[30].lines, asked, buffers[30].buftype or "" })
        end)
      end

      it("fails as documented when an autocommand closes the preview window as it gets the buffer", function()
        local set_buf = _G.vim.api.nvim_win_set_buf
        _G.vim.api.nvim_win_set_buf = spy.new(function(win, buf)
          set_buf(win, buf)
          win_buf[win] = nil -- autocmd BufWinEnter * ++nested if &previewwindow | close | endif
        end)
        local success, err = pcall(open_file_handler, { filePath = "test.txt", preview = true, startLine = 1 })
        expect(success).to_be_false()
        assert.are.same(
          { code = -32000, message = "File operation error", data = "No preview window shows the file" },
          err
        )
      end)

      for _, case in ipairs({
        { name = "the window", win = 1000 },
        { name = "the preview window", win = 3000, preview = true },
      }) do
        it("does not load another buffer that an autocommand shows in " .. case.name .. " instead", function()
          buffers[40] = { lines = { "plugin text" }, buftype = "nofile", loaded = true, filetype = "" }
          -- autocmd BufWinEnter test.txt ++nested buffer 40
          local run_cmd, set_buf = _G.vim.cmd, _G.vim.api.nvim_win_set_buf
          _G.vim.cmd = function(command)
            run_cmd(command)
            if command == "edit test.txt" then
              win_buf[case.win] = 40
            end
          end
          _G.vim.api.nvim_win_set_buf = function(win, buf)
            set_buf(win, buf)
            win_buf[win] = 40
          end
          pcall(open_file_handler, { filePath = "test.txt", preview = case.preview, startLine = 1 })
          assert.are.same({ { "plugin text" }, { "" } }, { buffers[40].lines, buffers[30].lines })
        end)
      end

      it("does not fail a write when an earlier BufWritePost autocommand wipes the buffer", function()
        -- autocmd BufWritePost *.tmp bwipeout. Neovim still runs the other BufWritePost autocommands.
        buffers[30] = nil
        _G.vim.api.nvim_buf_get_name = function(buf)
          return assert(buffers[buf] and "test.txt", "Invalid buffer id: " .. buf)
        end
        fire("BufUnload", 30)
        assert.has_no.errors(function()
          fire("BufWritePost", 30)
        end)
      end)

      it("keeps the empty buffer while the user holds Visual mode in the middle of a command", function()
        editor_mode, state_flags = "v", "S"
        local success = pcall(open_file_handler, { filePath = "test.txt", startText = "second" })
        expect(success).to_be_true()
        assert.are.same({ { "" }, false, "v" }, { buffers[30].lines, asked, editor_mode })
      end)
    end)

    describe("when a user's BufReadPost autocommand fails while the file is loaded again", function()
      before_each(function()
        buffers[30].loaded, buffers[30].read_error = true, true
        buffers[30].disk = { "alpha", "beta", "gamma", "delta", "epsilon", "zeta" }
      end)

      for _, case in ipairs({
        { name = "the window shows it", shown = 1000 },
        { name = "it is hidden" },
        { name = "it is hidden, with preview = true", preview = true },
      }) do
        it("ends the reload and then fails with the error when " .. case.name, function()
          if case.shown then
            win_buf[case.shown] = 30
          end
          local success, err = pcall(open_file_handler, { filePath = "test.txt", preview = case.preview })
          expect(success).to_be_false()
          assert_contains(tostring(err), "user boom")
          assert.are.same({ "alpha", "beta", "gamma", "delta", "epsilon", "zeta" }, buffers[30].lines)
          expect(win_buf[case.preview and 3000 or 1000]).to_be(30)
        end)
      end
    end)

    for _, case in ipairs({ { name = "the window shows it", shown = 1000 }, { name = "it is hidden" } }) do
      it("succeeds when an autocommand hides its own error during the reload and " .. case.name, function()
        buffers[30].loaded, buffers[30].handled_error = true, true
        buffers[30].disk = { "alpha", "beta", "fresh" }
        if case.shown then
          win_buf[case.shown] = 30
        end
        local success, result = pcall(open_file_handler, { filePath = "test.txt", startText = "fresh" })
        expect(success).to_be_true()
        expect(result.content[1].text).to_be('Opened file and selected text "fresh"')
      end)
    end

    describe(
      "when the file changed and Neovim's own check as a window gets the buffer skips FileChangedShell",
      function()
        before_each(function()
          _G.vim.o.autoread, buffers[30].loaded = false, true
          buffers[30].disk = { "alpha", "beta", "fresh" }
        end)

        it("never asks (W11) when every other window that shows it ignores the event in 'eventignorewin'", function()
          win_buf[2000], ignore_win[2000] = 30, "FileChangedShell"
          local success = pcall(open_file_handler, { filePath = "test.txt", startText = "fresh" })
          expect(success).to_be_true()
          expect(asked).to_be_false()
        end)

        for _, buftype in ipairs({ "acwrite", "nofile" }) do
          it(
            "keeps 'buftype' " .. buftype .. ", whose file Neovim never checks, when 'eventignore' ignores the event",
            function()
              _G.vim.o.eventignore, buffers[30].buftype = "FileChangedShell", buftype
              local success = pcall(open_file_handler, { filePath = "test.txt" })
              expect(success).to_be_true()
              assert.are.same({ buftype, false }, { buffers[30].buftype, asked })
            end
          )
        end

        it("never asks (W11) when 'eventignore' ignores the event for a hidden buffer, and keeps its text", function()
          _G.vim.o.eventignore = "FileChangedShell"
          local success = pcall(open_file_handler, { filePath = "test.txt", startText = "fresh" })
          expect(success).to_be_true()
          assert.are.same({ { "alpha", "beta", "gamma", "delta", "epsilon" }, false, "" }, {
            buffers[30].lines,
            asked,
            buffers[30].buftype or "",
          })
        end)
      end
    )

    describe("when the window already shows the file with unsaved changes", function()
      before_each(function()
        win_buf[1000], buffers[30].loaded, buffers[30].modified = 30, true, true
      end)

      it("selects in it and keeps the changes", function()
        local success, result = pcall(open_file_handler, { filePath = "test.txt", startLine = 2, endLine = 3 })
        expect(success).to_be_true()
        expect(result.content[1].text).to_be("Opened file and selected lines 2 to 3")
        assert.are.same({ win = 1000, text = "beta\ngamma" }, visual)
      end)

      it("shows it in the preview window with preview = true", function()
        expect(open({ startLine = 2, endLine = 3 })).to_be("Opened file and selected lines 2 to 3")
        assert.are.same({ win = 3000, text = "beta\ngamma" }, visual)
        expect(win_buf[1000]).to_be(30)
      end)

      it("shows it in the preview window while the user types in it", function()
        editor_mode = "i"
        local success, result = pcall(open_file_handler, { filePath = "test.txt", startLine = 2 })
        expect(success).to_be_true()
        assert_contains(result.content[1].text, "Opened file and positioned at line 2")
        assert.are.same({ 30, 30, 1000 }, { win_buf[1000], win_buf[3000], current_win })
        assert.are.same({ 2, 0 }, win_cursor[3000])
      end)
    end)

    describe("while the user is in the middle of a command", function()
      -- The user's next keys finish the command in the current window, from where it started: an operator waits for
      -- its motion, and Insert mode, Replace mode, CTRL-O from them and the command line wait for more keys.
      local note = " (shown in the preview window without a selection, because the user is in the middle of a command)"

      local function call(params)
        params.filePath = "test.txt"
        return pcall(open_file_handler, params)
      end

      for _, user in ipairs({
        { mode = "no" },
        { mode = "nov" },
        { mode = "niI" },
        { mode = "i" },
        { mode = "R" },
        { mode = "c" },
        { mode = "v", state = "S" },
        { mode = "s", state = "S" },
      }) do
        local mode = user.mode
        for _, case in ipairs({
          { params = {}, text = "Opened file: test.txt" },
          { params = { startLine = 2, endLine = 3 }, text = "Opened file and positioned at line 2", cursor = { 2, 0 } },
          {
            params = { startText = "beta", endText = "gamma" },
            text = 'Opened file and positioned at "beta"',
            cursor = { 2, 0 },
          },
        }) do
          it("keeps the current window, its cursor and mode " .. mode .. " for " .. case.text, function()
            editor_mode, state_flags = mode, user.state or ""
            local success, result = call(case.params)
            expect(success).to_be_true()
            assert.are.same(
              { current = 1000, buf = 10, cursor = nil, visual = nil, fed = {}, mode = mode, typed = {} },
              {
                current = current_win,
                buf = win_buf[1000],
                cursor = win_cursor[1000],
                visual = visual,
                fed = typeahead,
                mode = editor_mode,
                typed = typed_over_selection,
              }
            )
            expect(win_buf[3000]).to_be(30)
            assert.are.same(case.cursor, win_cursor[3000])
            expect(result.content[1].text).to_be(case.text .. note)
          end)
        end
      end

      it("reports the previewed file with makeFrontmost = false", function()
        editor_mode = "no"
        local success, result = call({ startLine = 2, makeFrontmost = false })
        expect(success).to_be_true()
        local parsed = require("tests.busted_setup").json_decode(result.content[1].text)
        expect(parsed.languageId).to_be("lua")
        expect(parsed.lineCount).to_be(5)
        expect(current_win).to_be(1000)
        expect(win_buf[1000]).to_be(10)
      end)

      it("changes nothing when the command started in the preview window", function()
        editor_mode, current_win, win_buf, preview_flag[3000] = "no", 3000, { [1000] = 10, [3000] = 10 }, true
        local success, err = call({ startLine = 2 })
        expect(success).to_be_false()
        expect(err.code).to_be(-32000)
        assert.are.same({ [1000] = 10, [3000] = 10 }, win_buf)
        assert.are.same({}, win_cursor)
        assert.are.same({}, _G.vim.cmd_history)
      end)
    end)
  end)

  describe("selection marks", function()
    before_each(function()
      buffer_lines = { "one", "two", "three", "four", "alpha beta gamma" }
    end)

    -- Neovim reads the keys waiting in typeahead as soon as the handler returns, then the keys the user types.
    local function read_typeahead()
      while #typeahead > 0 do
        local next_key = table.remove(typeahead, 1)
        if editor_mode:match("^no") then
          if next_key ~= "\27" then
            table.insert(operated_on, next_key)
          end
          editor_mode = "n"
        end
      end
    end

    local function open(params)
      params.filePath = "test.txt"
      local success, result = pcall(open_file_handler, params)
      expect(success).to_be_true()
      read_typeahead()
      return result.content[1].text
    end

    it("selects startLine through endLine as 1-based line numbers", function()
      expect(open({ startLine = 3, endLine = 4 })).to_be("Opened file and selected lines 3 to 4")
      assert.are.same({ 3, 0 }, marks["<"])
      assert.are.same({ 4, 3 }, marks[">"])
      expect(_G.vim.cmd_history[#_G.vim.cmd_history]).to_be("normal! gv")
    end)

    it("rejects a line below 1, a fractional or false line, or endLine below startLine before opening", function()
      for _, lines in ipairs({
        { startLine = false },
        { startLine = false, endLine = 3 },
        { startLine = 2, endLine = false },
        { startLine = 0 },
        { startLine = 2, endLine = 0 },
        { startLine = 1.5 },
        { startLine = 4, endLine = 3 },
      }) do
        _G.vim.cmd_history = {}
        lines.filePath = "test.txt"
        local success, err = pcall(open_file_handler, lines)
        expect(success).to_be_false()
        expect(err.code).to_be(-32602)
        expect(#_G.vim.cmd_history).to_be(0)
      end
    end)

    it("clamps an endLine past the end of the file to the last line and reports the clamped range", function()
      expect(open({ startLine = 4, endLine = 9 })).to_be("Opened file and selected lines 4 to 5")
      assert.are.same({ 4, 0 }, marks["<"])
      assert.are.same({ 5, 15 }, marks[">"])
    end)

    it("rejects a startLine past the end of the file before opening it", function()
      _G.vim.cmd_history = {}
      local success, err = pcall(open_file_handler, { filePath = "test.txt", startLine = 6 })
      expect(success).to_be_false()
      expect(err.code).to_be(-32602)
      expect(#_G.vim.cmd_history).to_be(0)
    end)

    it("accepts a startLine that exists only in the unsaved lines of the loaded buffer", function()
      edit_buffers["test.txt"] = 1
      _G.vim.fn.readfile = spy.new(function(path, flags, max)
        return { "one", "two" }
      end)
      expect(open({ startLine = 4, endLine = 5 })).to_be("Opened file and selected lines 4 to 5")
    end)

    it("uses the file on disk when :edit would not reuse a loaded buffer", function()
      -- For example a buffer loaded through a symlink that was retargeted since: Neovim keeps the old inode.
      _G.vim.fn.readfile = spy.new(function(path, flags, max)
        return { "one", "two" }
      end)
      local success, err = pcall(open_file_handler, { filePath = "test.txt", startLine = 4 })
      expect(success).to_be_false()
      expect(err.code).to_be(-32602)
    end)

    it("keeps the end mark on an empty endLine", function()
      buffer_lines = { "abc", "", "xyz" }
      expect(open({ startLine = 1, endLine = 2 })).to_be("Opened file and selected lines 1 to 2")
      assert.are.same({ 2, 0 }, marks[">"])
    end)

    it("sets both marks with no column offset on every path", function()
      for _, params in ipairs({
        { startLine = 3, endLine = 4 },
        { startText = "two", endText = "three" },
        { startText = "three" },
      }) do
        coladds = {}
        open(params)
        assert.are.same({ ["<"] = 0, [">"] = 0 }, coladds)
      end
    end)

    it("selects the whole first line for startLine = 1", function()
      expect(open({ startLine = 1 })).to_be("Opened file and selected lines 1 to 1")
      assert.are.same({ 1, 0 }, marks["<"])
      assert.are.same({ 1, 2 }, marks[">"])
    end)

    it("selects from the startText match through the last character of the endText match", function()
      expect(open({ startText = "two", endText = "three" })).to_be(
        'Opened file and selected text from "two" to "three"'
      )
      assert.are.same({ 2, 0 }, marks["<"])
      assert.are.same({ 3, 4 }, marks[">"])
    end)

    it("ends a mid-line endText selection on the match, not the character after it", function()
      expect(open({ startText = "alpha", endText = "beta" })).to_be(
        'Opened file and selected text from "alpha" to "beta"'
      )
      assert.are.same({ 5, 0 }, marks["<"])
      assert.are.same({ 5, 9 }, marks[">"])
    end)

    it("ends on an endText match after startText, not one earlier on the same line", function()
      buffer_lines = { "end -- start of block", "  body", "end" }
      expect(open({ startText = "start", endText = "end" })).to_be(
        'Opened file and selected text from "start" to "end"'
      )
      assert.are.same({ 1, 7 }, marks["<"])
      assert.are.same({ 3, 2 }, marks[">"])
    end)

    it("ends a selectToEndOfLine selection on the last character, not on the line break", function()
      open({ startText = "two", endText = "three", selectToEndOfLine = true })
      assert.are.same({ 2, 0 }, marks["<"])
      assert.are.same({ 3, 4 }, marks[">"])
    end)

    it("puts the end mark one past the last character when 'selection' is exclusive", function()
      _G.vim.o.selection = "exclusive"
      open({ startLine = 3, endLine = 4 })
      assert.are.same({ 4, 4 }, marks[">"])
      open({ startText = "alpha", endText = "beta" })
      assert.are.same({ 5, 10 }, marks[">"])
      open({ startText = "three" })
      assert.are.same({ 3, 5 }, marks[">"])
    end)

    it("only places the cursor when one call selects lines and then misses endText", function()
      for _, mode in ipairs({ "v", "s" }) do
        gv_mode = mode
        local text = open({ startLine = 3, endLine = 4, startText = "two", endText = "zzz" })
        assert_contains(text, 'Opened file and positioned at "two"')
        expect(editor_mode).to_be("n")
        assert.are.same({ 2, 0 }, cursor)
      end
    end)

    it("never types over a selection that gv starts in Select mode", function()
      gv_mode = "s"
      for _, case in ipairs({
        { params = { startText = "two", endText = "three" }, mode = "s" },
        { params = { startText = "three" }, mode = "s" },
        { params = { startLine = 3, endLine = 4 }, mode = "s" },
        { params = { startLine = 3, endLine = 4, startText = "two", endText = "three" }, mode = "s" },
        { params = { startLine = 3, endLine = 4, startText = "two", endText = "zzz" }, mode = "n" },
      }) do
        open(case.params)
        assert.are.same({}, typed_over_selection)
        expect(editor_mode).to_be(case.mode)
      end
    end)

    it("selects as usual from Terminal, Visual and Select mode, which are between commands", function()
      for _, user in ipairs({ { mode = "t", state = "S" }, { mode = "nt" }, { mode = "v" }, { mode = "s" } }) do
        editor_mode, state_flags, _G.vim.cmd_history = user.mode, user.state or "", {}
        expect(open({ startLine = 3, endLine = 4 })).to_be("Opened file and selected lines 3 to 4")
        expect(_G.vim.cmd_history[1]).to_be("edit test.txt")
        expect(editor_mode).to_be("v")
      end
    end)

    it("leaves a Select mode the user holds in another window before gv", function()
      _G.vim.api.nvim_list_wins = spy.new(function()
        return { 2000 }
      end)
      editor_mode = "s"
      expect(open({ startLine = 3, endLine = 4 })).to_be("Opened file and selected lines 3 to 4")
      assert.are.same({}, typed_over_selection)
      expect(editor_mode).to_be("v")
    end)

    it("selects charwise after a linewise or blockwise Visual mode in the buffer", function()
      for _, case in ipairs({
        { last = "V", mode = "n", gv = "v", want = "v" },
        { last = "\22", mode = "n", gv = "v", want = "v" },
        { last = "v", mode = "V", gv = "v", want = "v" },
        { last = "v", mode = "S", gv = "s", want = "s" },
        { last = "\22", mode = "n", gv = "s", want = "s" },
      }) do
        last_visual, editor_mode, gv_mode = case.last, case.mode, case.gv
        open({ startText = "two", endText = "three" })
        expect(editor_mode).to_be(case.want)
        assert.are.same({}, typed_over_selection)
      end
    end)

    it("selects only the startText match when there is no endText", function()
      expect(open({ startText = "three" })).to_be('Opened file and selected text "three"')
      assert.are.same({ 3, 0 }, marks["<"])
      assert.are.same({ 3, 4 }, marks[">"])
    end)

    it("puts the cursor on the startText match without a selection when endText is not found", function()
      assert_contains(open({ startText = "two", endText = "zzz" }), 'Opened file and positioned at "two"')
      assert.are.same({ 2, 0 }, cursor)
      assert.are.same({}, marks)
      for _, command in ipairs(_G.vim.cmd_history) do
        expect(command == "normal! gv").to_be_false()
      end
    end)
  end)

  it("should handle text pattern selection when pattern found", function()
    local params = {
      filePath = "test.txt",
      startText = "function",
      endText = "end",
      selectToEndOfLine = true,
    }

    local success, result = pcall(open_file_handler, params)

    expect(success).to_be_true()
    expect(result.content).to_be_table()
    expect(result.content[1].type).to_be("text")
    -- Since the mock buffer contains "function" and "end", selection should work
    expect(result.content[1].text).to_be('Opened file and selected text from "function" to "end"')
  end)

  it("should handle text pattern selection when pattern not found", function()
    -- Mock search to return 0 (not found)
    _G.vim.fn.search = spy.new(function(pattern)
      return 0 -- Pattern not found
    end)

    local params = {
      filePath = "test.txt",
      startText = "nonexistent",
    }

    local success, result = pcall(open_file_handler, params)

    expect(success).to_be_true()
    expect(result.content).to_be_table()
    expect(result.content[1].type).to_be("text")
    assert_contains(result.content[1].text, "not found")
  end)
end)
