require("tests.busted_setup") -- Ensure test helpers are loaded

describe("Tool: open_file", function()
  local open_file_handler

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
    _G.vim.cmd = spy.new(function(command)
      table.insert(_G.vim.cmd_history, command)
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
      return 10 -- Mock line count
    end)
    _G.vim.api.nvim_buf_set_mark = spy.new(function(buf, name, line, col, opts)
      -- Mock mark setting
    end)
    _G.vim.api.nvim_buf_get_lines = spy.new(function(buf, start, end_line, strict)
      -- Mock buffer lines for search
      return {
        "local function test()",
        "  print('hello')",
        "  return true",
        "end",
      }
    end)
    _G.vim.api.nvim_win_set_cursor = spy.new(function(win, pos)
      -- Mock cursor setting
    end)
  end)

  after_each(function()
    -- Clean up global mocks if necessary, though spy.restore() is better if using full spy.lua
    _G.vim.fn.expand = nil
    _G.vim.fn.filereadable = nil
    _G.vim.fn.fnameescape = nil
    _G.vim.cmd = nil
    _G.vim.cmd_history = nil
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
    assert.spy(_G.vim.fn.expand).was_called_with("non_readable_file.txt")
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

    assert.spy(_G.vim.fn.expand).was_called_with("readable_file.txt")
    assert.spy(_G.vim.fn.filereadable).was_called_with("readable_file.txt")
    assert.spy(_G.vim.fn.fnameescape).was_called_with("readable_file.txt")

    expect(#_G.vim.cmd_history).to_be(1)
    expect(_G.vim.cmd_history[1]).to_be("edit readable_file.txt")
  end)

  it("should handle filePath needing expansion", function()
    _G.vim.fn.expand = spy.new(function(path)
      if path == "~/.config/nvim/init.lua" then
        return "/Users/testuser/.config/nvim/init.lua"
      end
      return path
    end)
    local params = { filePath = "~/.config/nvim/init.lua" }
    local success, result = pcall(open_file_handler, params)

    expect(success).to_be_true()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")
    expect(result.content[1].text).to_be("Opened file: /Users/testuser/.config/nvim/init.lua")
    assert.spy(_G.vim.fn.expand).was_called_with("~/.config/nvim/init.lua")
    assert.spy(_G.vim.fn.filereadable).was_called_with("/Users/testuser/.config/nvim/init.lua")
    assert.spy(_G.vim.fn.fnameescape).was_called_with("/Users/testuser/.config/nvim/init.lua")
    expect(_G.vim.cmd_history[1]).to_be("edit /Users/testuser/.config/nvim/init.lua")
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

  it("should handle line selection parameters", function()
    -- Mock additional functions needed for line selection
    _G.vim.api.nvim_win_set_cursor = spy.new(function(win, pos)
      -- Mock cursor setting
    end)
    _G.vim.fn.setpos = spy.new(function(mark, pos)
      -- Mock position setting
    end)

    local params = { filePath = "test.txt", startLine = 5, endLine = 10 }
    local success, result = pcall(open_file_handler, params)

    expect(success).to_be_true()
    expect(result.content).to_be_table()
    expect(result.content[1].type).to_be("text")
    expect(result.content[1].text).to_be("Opened file and selected lines 5 to 10")
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
