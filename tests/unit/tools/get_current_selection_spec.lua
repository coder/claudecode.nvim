require("tests.busted_setup") -- Ensure test helpers are loaded

describe("Tool: get_current_selection", function()
  local get_current_selection_handler
  local mock_selection_module

  before_each(function()
    -- Mock the selection module
    mock_selection_module = {
      get_latest_selection = spy.new(function()
        -- Default behavior: no selection
        return nil
      end),
    }
    package.loaded["claudecode.selection"] = mock_selection_module

    -- Reset and require the module under test
    package.loaded["claudecode.tools.get_current_selection"] = nil
    get_current_selection_handler = require("claudecode.tools.get_current_selection").handler

    -- Mock vim.api and vim.json functions that might be called by the fallback if no selection
    _G.vim = _G.vim or {}
    _G.vim.api = _G.vim.api or {}
    _G.vim.json = _G.vim.json or {}
    _G.vim.api.nvim_get_current_buf = spy.new(function()
      return 1
    end)
    _G.vim.api.nvim_buf_get_name = spy.new(function(bufnr)
      if bufnr == 1 then
        return "/current/file.lua"
      end
      return "unknown_buffer"
    end)
    _G.vim.json.encode = spy.new(function(data, opts)
      return require("tests.busted_setup").json_encode(data)
    end)
  end)

  after_each(function()
    package.loaded["claudecode.selection"] = nil
    package.loaded["claudecode.tools.get_current_selection"] = nil
    _G.vim.api.nvim_get_current_buf = nil
    _G.vim.api.nvim_buf_get_name = nil
    _G.vim.json.encode = nil
  end)

  it("should return an empty selection structure if no selection is available", function()
    mock_selection_module.get_latest_selection = spy.new(function()
      return nil
    end)

    local success, result = pcall(get_current_selection_handler, {})
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.success).to_be_true() -- New success field
    expect(parsed_result.text).to_be("")
    expect(parsed_result.filePath).to_be("/current/file.lua")
    expect(parsed_result.selection.isEmpty).to_be_true()
    expect(parsed_result.selection.start.line).to_be(0) -- Default empty selection
    expect(parsed_result.selection.start.character).to_be(0)
    assert.spy(mock_selection_module.get_latest_selection).was_called()
  end)

  it("should return the selection data from claudecode.selection if available", function()
    local mock_sel_data = {
      text = "selected text",
      filePath = "/path/to/file.lua",
      fileUrl = "file:///path/to/file.lua",
      selection = {
        start = { line = 10, character = 4 },
        ["end"] = { line = 10, character = 17 },
        isEmpty = false,
      },
    }
    mock_selection_module.get_latest_selection = spy.new(function()
      return mock_sel_data
    end)

    local success, result = pcall(get_current_selection_handler, {})
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    -- Should return the selection data with success field added
    local expected_result = vim.tbl_extend("force", mock_sel_data, { success = true })
    assert.are.same(expected_result, parsed_result)
    assert.spy(mock_selection_module.get_latest_selection).was_called()
  end)

  it("should return error format when no active editor is found", function()
    mock_selection_module.get_latest_selection = spy.new(function()
      return nil
    end)

    -- Mock empty buffer name to simulate no active editor
    _G.vim.api.nvim_buf_get_name = spy.new(function()
      return ""
    end)

    local success, result = pcall(get_current_selection_handler, {})
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.success).to_be_false()
    expect(parsed_result.message).to_be("No active editor found")
    -- Should not have other fields when success is false
    expect(parsed_result.text).to_be_nil()
    expect(parsed_result.filePath).to_be_nil()
    expect(parsed_result.selection).to_be_nil()
  end)

  it("should handle pcall failure when requiring selection module", function()
    -- Simulate require failing
    package.loaded["claudecode.selection"] = nil -- Ensure it's not cached
    local original_require = _G.require
    _G.require = function(mod_name)
      if mod_name == "claudecode.selection" then
        error("Simulated require failure for claudecode.selection")
      end
      return original_require(mod_name)
    end

    local success, err = pcall(get_current_selection_handler, {})
    _G.require = original_require -- Restore original require

    expect(success).to_be_false()
    expect(err).to_be_table()
    expect(err.code).to_be(-32000)
    assert_contains(err.message, "Internal server error")
    assert_contains(err.data, "Failed to load selection module")
  end)
end)
