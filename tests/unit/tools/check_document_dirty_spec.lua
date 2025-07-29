require("tests.busted_setup") -- Ensure test helpers are loaded

describe("Tool: check_document_dirty", function()
  local check_document_dirty_handler

  before_each(function()
    package.loaded["claudecode.tools.check_document_dirty"] = nil
    check_document_dirty_handler = require("claudecode.tools.check_document_dirty").handler

    _G.vim = _G.vim or {}
    _G.vim.fn = _G.vim.fn or {}
    _G.vim.api = _G.vim.api or {}

    -- Mock vim.json.encode
    _G.vim.json = _G.vim.json or {}
    _G.vim.json.encode = spy.new(function(data, opts)
      return require("tests.busted_setup").json_encode(data)
    end)

    -- Default mocks
    _G.vim.fn.bufnr = spy.new(function(filePath)
      if filePath == "/path/to/open_file.lua" then
        return 1
      end
      if filePath == "/path/to/another_open_file.txt" then
        return 2
      end
      return -1 -- File not open
    end)
    _G.vim.api.nvim_buf_get_option = spy.new(function(bufnr, option_name)
      if option_name == "modified" then
        if bufnr == 1 then
          return false
        end -- open_file.lua is clean
        if bufnr == 2 then
          return true
        end -- another_open_file.txt is dirty
      end
      return nil -- Default for other options or unknown bufnr
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function(bufnr)
      if bufnr == 1 then
        return "/path/to/open_file.lua"
      end
      if bufnr == 2 then
        return "/path/to/another_open_file.txt"
      end
      return ""
    end)
  end)

  after_each(function()
    package.loaded["claudecode.tools.check_document_dirty"] = nil
    _G.vim.fn.bufnr = nil
    _G.vim.api.nvim_buf_get_option = nil
    _G.vim.api.nvim_buf_get_name = nil
    _G.vim.json.encode = nil
  end)

  it("should error if filePath parameter is missing", function()
    local success, err = pcall(check_document_dirty_handler, {})
    expect(success).to_be_false()
    expect(err).to_be_table()
    expect(err.code).to_be(-32602)
    assert_contains(err.data, "Missing filePath parameter")
  end)

  it("should return success=false if file is not open in editor", function()
    local params = { filePath = "/path/to/non_open_file.py" }
    local success, result = pcall(check_document_dirty_handler, params)
    expect(success).to_be_true() -- No longer throws error, returns success=false
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.success).to_be_false()
    expect(parsed_result.message).to_be("Document not open: /path/to/non_open_file.py")

    assert.spy(_G.vim.fn.bufnr).was_called_with("/path/to/non_open_file.py")
  end)

  it("should return isDirty=false for a clean open file", function()
    local params = { filePath = "/path/to/open_file.lua" }
    local success, result = pcall(check_document_dirty_handler, params)
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.success).to_be_true()
    expect(parsed_result.isDirty).to_be_false()
    expect(parsed_result.isUntitled).to_be_false()
    expect(parsed_result.filePath).to_be("/path/to/open_file.lua")

    assert.spy(_G.vim.fn.bufnr).was_called_with("/path/to/open_file.lua")
    assert.spy(_G.vim.api.nvim_buf_get_option).was_called_with(1, "modified")
  end)

  it("should return isDirty=true for a dirty open file", function()
    local params = { filePath = "/path/to/another_open_file.txt" }
    local success, result = pcall(check_document_dirty_handler, params)
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.success).to_be_true()
    expect(parsed_result.isDirty).to_be_true()
    expect(parsed_result.isUntitled).to_be_false()
    expect(parsed_result.filePath).to_be("/path/to/another_open_file.txt")

    assert.spy(_G.vim.fn.bufnr).was_called_with("/path/to/another_open_file.txt")
    assert.spy(_G.vim.api.nvim_buf_get_option).was_called_with(2, "modified")
  end)
end)
