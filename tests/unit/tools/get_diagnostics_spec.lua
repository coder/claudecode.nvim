require("tests.busted_setup") -- Ensure test helpers are loaded

describe("Tool: get_diagnostics", function()
  local get_diagnostics_handler

  before_each(function()
    package.loaded["claudecode.tools.get_diagnostics"] = nil
    package.loaded["claudecode.logger"] = nil

    -- Mock the logger module
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      error = function() end,
      info = function() end,
      warn = function() end,
    }

    get_diagnostics_handler = require("claudecode.tools.get_diagnostics").handler

    _G.vim = _G.vim or {}
    _G.vim.lsp = _G.vim.lsp or {} -- Ensure vim.lsp exists for the check
    _G.vim.diagnostic = _G.vim.diagnostic or {}
    _G.vim.api = _G.vim.api or {}
    _G.vim.fn = _G.vim.fn or {}

    -- Default mocks
    _G.vim.diagnostic.get = spy.new(function()
      return {}
    end) -- Default to no diagnostics
    _G.vim.api.nvim_buf_get_name = spy.new(function(bufnr)
      return "/path/to/file_for_buf_" .. tostring(bufnr) .. ".lua"
    end)
    _G.vim.json.encode = spy.new(function(obj)
      return vim.inspect(obj) -- Use vim.inspect as a simple serialization
    end)
    _G.vim.fn.bufnr = spy.new(function(filepath)
      -- Mock buffer lookup
      if filepath == "/test/file.lua" then
        return 1
      end
      return -1 -- File not open
    end)
    _G.vim.uri_to_fname = spy.new(function(uri)
      -- Realistic mock that matches vim.uri_to_fname behavior
      if uri:sub(1, 7) == "file://" then
        return uri:sub(8)
      end
      -- Real vim.uri_to_fname throws an error for URIs without proper scheme
      error("URI must contain a scheme: " .. uri)
    end)
  end)

  after_each(function()
    package.loaded["claudecode.tools.get_diagnostics"] = nil
    package.loaded["claudecode.logger"] = nil
    _G.vim.diagnostic.get = nil
    _G.vim.api.nvim_buf_get_name = nil
    _G.vim.json.encode = nil
    _G.vim.fn.bufnr = nil
    _G.vim.uri_to_fname = nil
    -- Note: We don't nullify _G.vim.lsp or _G.vim.diagnostic entirely
    -- as they are checked for existence.
  end)

  it("should return an empty list if no diagnostics are found", function()
    local success, result = pcall(get_diagnostics_handler, {})
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(#result.content).to_be(0)
    assert.spy(_G.vim.diagnostic.get).was_called_with(nil)
  end)

  it("should return formatted diagnostics if available", function()
    local mock_diagnostics = {
      { bufnr = 1, lnum = 10, col = 5, severity = 1, message = "Error message 1", source = "linter1" },
      { bufnr = 2, lnum = 20, col = 15, severity = 2, message = "Warning message 2", source = "linter2" },
    }
    _G.vim.diagnostic.get = spy.new(function()
      return mock_diagnostics
    end)

    local success, result = pcall(get_diagnostics_handler, {})
    expect(success).to_be_true()
    expect(result.content).to_be_table()
    expect(#result.content).to_be(2)

    -- Check that results are MCP content items
    expect(result.content[1].type).to_be("text")
    expect(result.content[2].type).to_be("text")

    -- Verify JSON encoding was called with correct structure
    assert.spy(_G.vim.json.encode).was_called(2)

    -- Check the first diagnostic was encoded with 1-indexed values
    local first_call_args = _G.vim.json.encode.calls[1].vals[1]
    expect(first_call_args.filePath).to_be("/path/to/file_for_buf_1.lua")
    expect(first_call_args.line).to_be(11) -- 10 + 1 for 1-indexing
    expect(first_call_args.character).to_be(6) -- 5 + 1 for 1-indexing
    expect(first_call_args.severity).to_be(1)
    expect(first_call_args.message).to_be("Error message 1")
    expect(first_call_args.source).to_be("linter1")

    assert.spy(_G.vim.api.nvim_buf_get_name).was_called_with(1)
    assert.spy(_G.vim.api.nvim_buf_get_name).was_called_with(2)
  end)

  it("should filter out diagnostics with no file path", function()
    local mock_diagnostics = {
      { bufnr = 1, lnum = 10, col = 5, severity = 1, message = "Error message 1", source = "linter1" },
      { bufnr = 99, lnum = 20, col = 15, severity = 2, message = "Warning message 2", source = "linter2" }, -- This one will have no path
    }
    _G.vim.diagnostic.get = spy.new(function()
      return mock_diagnostics
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function(bufnr)
      if bufnr == 1 then
        return "/path/to/file1.lua"
      end
      if bufnr == 99 then
        return ""
      end -- No path for bufnr 99
      return "other.lua"
    end)

    local success, result = pcall(get_diagnostics_handler, {})
    expect(success).to_be_true()
    expect(#result.content).to_be(1)

    -- Verify only the diagnostic with a file path was included
    assert.spy(_G.vim.json.encode).was_called(1)
    local encoded_args = _G.vim.json.encode.calls[1].vals[1]
    expect(encoded_args.filePath).to_be("/path/to/file1.lua")
  end)

  it("should error if vim.diagnostic.get is not available", function()
    _G.vim.diagnostic.get = nil
    local success, err = pcall(get_diagnostics_handler, {})
    expect(success).to_be_false()
    expect(err).to_be_table()
    expect(err.code).to_be(-32000)
    assert_contains(err.message, "Feature unavailable")
    assert_contains(err.data, "Diagnostics not available in this editor version/configuration.")
  end)

  it("should error if vim.diagnostic is not available", function()
    local old_diagnostic = _G.vim.diagnostic
    _G.vim.diagnostic = nil
    local success, err = pcall(get_diagnostics_handler, {})
    _G.vim.diagnostic = old_diagnostic -- Restore

    expect(success).to_be_false()
    expect(err.code).to_be(-32000)
  end)

  it("should error if vim.lsp is not available for the check (though diagnostic is primary)", function()
    local old_lsp = _G.vim.lsp
    _G.vim.lsp = nil
    local success, err = pcall(get_diagnostics_handler, {})
    _G.vim.lsp = old_lsp -- Restore

    expect(success).to_be_false()
    expect(err.code).to_be(-32000)
  end)

  it("should filter diagnostics by URI when provided", function()
    local mock_diagnostics = {
      { bufnr = 1, lnum = 10, col = 5, severity = 1, message = "Error in file1", source = "linter1" },
    }
    _G.vim.diagnostic.get = spy.new(function(bufnr)
      if bufnr == 1 then
        return mock_diagnostics
      end
      return {}
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function(bufnr)
      if bufnr == 1 then
        return "/test/file.lua"
      end
      return ""
    end)

    local success, result = pcall(get_diagnostics_handler, { uri = "file:///test/file.lua" })
    expect(success).to_be_true()
    expect(#result.content).to_be(1)

    -- Should have used vim.uri_to_fname to convert URI to file path
    assert.spy(_G.vim.uri_to_fname).was_called_with("file:///test/file.lua")
    assert.spy(_G.vim.diagnostic.get).was_called_with(1)
    assert.spy(_G.vim.fn.bufnr).was_called_with("/test/file.lua")
  end)

  it("should error for URI of unopened file", function()
    _G.vim.fn.bufnr = spy.new(function()
      return -1 -- File not open
    end)

    local success, err = pcall(get_diagnostics_handler, { uri = "file:///unknown/file.lua" })
    expect(success).to_be_false()
    expect(err).to_be_table()
    expect(err.code).to_be(-32001)
    expect(err.message).to_be("File not open")
    assert_contains(err.data, "File must be open to retrieve diagnostics: /unknown/file.lua")

    -- Should have used vim.uri_to_fname and checked for buffer but not called vim.diagnostic.get
    assert.spy(_G.vim.uri_to_fname).was_called_with("file:///unknown/file.lua")
    assert.spy(_G.vim.fn.bufnr).was_called_with("/unknown/file.lua")
    assert.spy(_G.vim.diagnostic.get).was_not_called()
  end)
end)
