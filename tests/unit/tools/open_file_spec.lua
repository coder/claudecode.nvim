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

  before_each(function()
    -- Reset mocks and require the module under test
    package.loaded["claudecode.tools.open_file"] = nil
    open_file_handler = require("claudecode.tools.open_file").handler

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
    -- Like Neovim, gv enters Visual mode (Select mode when 'selectmode' has "cmd"), and :edit or <Esc> ends it.
    editor_mode = "n"
    gv_mode = "v"
    _G.vim.cmd = spy.new(function(command)
      table.insert(_G.vim.cmd_history, command)
      if command == "normal! gv" then
        editor_mode = gv_mode
      elseif command == "normal! \27" or command:match("^p?edit ") then
        editor_mode = "n"
      end
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
      return callback() -- Just execute the callback
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
    _G.vim.o.selection = "inclusive"
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
    _G.vim.api.nvim_buf_is_loaded = original_buf_is_loaded
    _G.vim.api.nvim_get_mode = original_get_mode
    _G.vim.o.selection = nil
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

  it("should handle preview mode parameter", function()
    local params = { filePath = "test.txt", preview = true }
    local success, result = pcall(open_file_handler, params)

    expect(success).to_be_true()
    expect(result.content[1].text).to_be("Opened file: test.txt")
    -- Preview mode affects window behavior but basic functionality should work
  end)

  describe("selection marks", function()
    before_each(function()
      buffer_lines = { "one", "two", "three", "four", "alpha beta gamma" }
    end)

    local function open(params)
      params.filePath = "test.txt"
      local success, result = pcall(open_file_handler, params)
      expect(success).to_be_true()
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
