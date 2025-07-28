require("tests.busted_setup") -- Ensure test helpers are loaded

describe("Tool: get_open_editors", function()
  local get_open_editors_handler

  before_each(function()
    package.loaded["claudecode.tools.get_open_editors"] = nil
    get_open_editors_handler = require("claudecode.tools.get_open_editors").handler

    _G.vim = _G.vim or {}
    _G.vim.api = _G.vim.api or {}
    _G.vim.fn = _G.vim.fn or {}
    _G.vim.json = _G.vim.json or {}

    -- Mock vim.json.encode
    _G.vim.json.encode = spy.new(function(data, opts)
      return require("tests.busted_setup").json_encode(data)
    end)

    -- Default mocks
    _G.vim.api.nvim_list_bufs = spy.new(function()
      return {}
    end)
    _G.vim.api.nvim_buf_is_loaded = spy.new(function()
      return false
    end)
    _G.vim.fn.buflisted = spy.new(function()
      return 0
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function()
      return ""
    end)
    _G.vim.api.nvim_buf_get_option = spy.new(function()
      return false
    end)
    _G.vim.api.nvim_get_current_buf = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_get_current_tabpage = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_buf_line_count = spy.new(function()
      return 10
    end)
    _G.vim.fn.fnamemodify = spy.new(function(path, modifier)
      if modifier == ":t" then
        return path:match("[^/]+$") or path -- Extract filename
      end
      return path
    end)
  end)

  after_each(function()
    package.loaded["claudecode.tools.get_open_editors"] = nil
    -- Clear mocks
    _G.vim.api.nvim_list_bufs = nil
    _G.vim.api.nvim_buf_is_loaded = nil
    _G.vim.fn.buflisted = nil
    _G.vim.api.nvim_buf_get_name = nil
    _G.vim.api.nvim_buf_get_option = nil
    _G.vim.api.nvim_get_current_buf = nil
    _G.vim.api.nvim_get_current_tabpage = nil
    _G.vim.api.nvim_buf_line_count = nil
    _G.vim.fn.fnamemodify = nil
    _G.vim.json.encode = nil
  end)

  it("should return an empty list if no listed buffers are found", function()
    local success, result = pcall(get_open_editors_handler, {})
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.tabs).to_be_table()
    expect(#parsed_result.tabs).to_be(0)
  end)

  it("should return a list of open and listed editors", function()
    -- Ensure fresh api and fn tables for this specific test's mocks
    _G.vim.api = {} -- Keep api mock specific to this test's needs
    _G.vim.fn = { ---@type vim_fn_table
      -- Add common stubs, buflisted will be spied below
      mode = function()
        return "n"
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
      end, -- Stub for type, will be spied
      -- buflisted will be spied
      bufname = function(_)
        return "mockbuffer"
      end,
      bufnr = function(_)
        return 1
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
      getpos = function(_)
        return { 0, 1, 1, 0 }
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
    }

    _G.vim.api.nvim_list_bufs = spy.new(function()
      return { 1, 2, 3 }
    end)
    _G.vim.api.nvim_buf_is_loaded = spy.new(function(bufnr)
      return bufnr == 1 or bufnr == 2 -- Buffer 3 is not loaded
    end)
    _G.vim.fn.buflisted = spy.new(function(bufnr)
      -- The handler checks `vim.fn.buflisted(bufnr) == 1`
      if bufnr == 1 or bufnr == 2 then
        return 1
      end
      return 0 -- Buffer 3 not listed
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function(bufnr)
      if bufnr == 1 then
        return "/path/to/file1.lua"
      end
      if bufnr == 2 then
        return "/path/to/file2.txt"
      end
      return ""
    end)
    _G.vim.api.nvim_buf_get_option = spy.new(function(bufnr, opt_name)
      if opt_name == "modified" then
        return bufnr == 2 -- file2.txt is dirty
      elseif opt_name == "filetype" then
        if bufnr == 1 then
          return "lua"
        elseif bufnr == 2 then
          return "text"
        end
      end
      return false
    end)
    _G.vim.api.nvim_get_current_buf = spy.new(function()
      return 1 -- Buffer 1 is active
    end)
    _G.vim.api.nvim_get_current_tabpage = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_buf_line_count = spy.new(function(bufnr)
      if bufnr == 1 then
        return 100
      elseif bufnr == 2 then
        return 50
      end
      return 0
    end)
    _G.vim.fn.fnamemodify = spy.new(function(path, modifier)
      if modifier == ":t" then
        return path:match("[^/]+$") or path -- Extract filename
      end
      return path
    end)
    _G.vim.json.encode = spy.new(function(data, opts)
      return require("tests.busted_setup").json_encode(data)
    end)

    local success, result = pcall(get_open_editors_handler, {})
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.tabs).to_be_table()
    expect(#parsed_result.tabs).to_be(2)

    expect(parsed_result.tabs[1].uri).to_be("file:///path/to/file1.lua")
    expect(parsed_result.tabs[1].isActive).to_be_true()
    expect(parsed_result.tabs[1].label).to_be("file1.lua")
    expect(parsed_result.tabs[1].languageId).to_be("lua")
    expect(parsed_result.tabs[1].isDirty).to_be_false()

    expect(parsed_result.tabs[2].uri).to_be("file:///path/to/file2.txt")
    expect(parsed_result.tabs[2].isActive).to_be_false()
    expect(parsed_result.tabs[2].label).to_be("file2.txt")
    expect(parsed_result.tabs[2].languageId).to_be("text")
    expect(parsed_result.tabs[2].isDirty).to_be_true()
  end)

  it("should include VS Code-compatible fields for each tab", function()
    -- Mock selection module to prevent errors
    package.loaded["claudecode.selection"] = {
      get_latest_selection = function()
        return nil
      end,
    }

    -- Mock all necessary API calls
    _G.vim.api.nvim_list_bufs = spy.new(function()
      return { 1 }
    end)
    _G.vim.api.nvim_buf_is_loaded = spy.new(function()
      return true
    end)
    _G.vim.fn.buflisted = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function()
      return "/path/to/test.lua"
    end)
    _G.vim.api.nvim_buf_get_option = spy.new(function(bufnr, opt_name)
      if opt_name == "modified" then
        return false
      elseif opt_name == "filetype" then
        return "lua"
      end
      return nil
    end)
    _G.vim.api.nvim_get_current_buf = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_get_current_tabpage = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_buf_line_count = spy.new(function()
      return 42
    end)
    _G.vim.fn.fnamemodify = spy.new(function(path, modifier)
      if modifier == ":t" then
        return "test.lua"
      end
      return path
    end)

    local success, result = pcall(get_open_editors_handler, {})
    expect(success).to_be_true()

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.tabs).to_be_table()
    expect(#parsed_result.tabs).to_be(1)

    local tab = parsed_result.tabs[1]

    -- Check all VS Code-compatible fields
    expect(tab.uri).to_be("file:///path/to/test.lua")
    expect(tab.isActive).to_be_true()
    expect(tab.isPinned).to_be_false()
    expect(tab.isPreview).to_be_false()
    expect(tab.isDirty).to_be_false()
    expect(tab.label).to_be("test.lua")
    expect(tab.groupIndex).to_be(0) -- 0-based
    expect(tab.viewColumn).to_be(1) -- 1-based
    expect(tab.isGroupActive).to_be_true()
    expect(tab.fileName).to_be("/path/to/test.lua")
    expect(tab.languageId).to_be("lua")
    expect(tab.lineCount).to_be(42)
    expect(tab.isUntitled).to_be_false()

    -- Clean up selection module mock
    package.loaded["claudecode.selection"] = nil
  end)

  it("should filter out buffers that are not loaded", function()
    _G.vim.api.nvim_list_bufs = spy.new(function()
      return { 1 }
    end)
    _G.vim.api.nvim_buf_is_loaded = spy.new(function()
      return false
    end) -- Not loaded
    _G.vim.fn.buflisted = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function()
      return "/path/to/file1.lua"
    end)

    local success, result = pcall(get_open_editors_handler, {})
    expect(success).to_be_true()
    expect(result.content).to_be_table()
    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(#parsed_result.tabs).to_be(0)
  end)

  it("should filter out buffers that are not listed", function()
    _G.vim.api.nvim_list_bufs = spy.new(function()
      return { 1 }
    end)
    _G.vim.api.nvim_buf_is_loaded = spy.new(function()
      return true
    end)
    _G.vim.fn.buflisted = spy.new(function()
      return 0
    end) -- Not listed
    _G.vim.api.nvim_buf_get_name = spy.new(function()
      return "/path/to/file1.lua"
    end)

    local success, result = pcall(get_open_editors_handler, {})
    expect(success).to_be_true()
    expect(result.content).to_be_table()
    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(#parsed_result.tabs).to_be(0)
  end)

  it("should filter out buffers with no file path", function()
    _G.vim.api.nvim_list_bufs = spy.new(function()
      return { 1 }
    end)
    _G.vim.api.nvim_buf_is_loaded = spy.new(function()
      return true
    end)
    _G.vim.fn.buflisted = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function()
      return ""
    end) -- Empty path

    local success, result = pcall(get_open_editors_handler, {})
    expect(success).to_be_true()
    expect(result.content).to_be_table()
    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(#parsed_result.tabs).to_be(0)
  end)
end)
