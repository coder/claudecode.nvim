require("tests.busted_setup") -- Ensure test helpers are loaded

describe("Tool: get_latest_selection", function()
  local get_latest_selection_handler
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
    package.loaded["claudecode.tools.get_latest_selection"] = nil
    get_latest_selection_handler = require("claudecode.tools.get_latest_selection").handler

    -- Mock vim.json functions
    _G.vim = _G.vim or {}
    _G.vim.json = _G.vim.json or {}
    _G.vim.json.encode = spy.new(function(data, opts)
      return require("tests.busted_setup").json_encode(data)
    end)
  end)

  after_each(function()
    package.loaded["claudecode.selection"] = nil
    package.loaded["claudecode.tools.get_latest_selection"] = nil
    _G.vim.json.encode = nil
  end)

  it("should return success=false if no selection is available", function()
    mock_selection_module.get_latest_selection = spy.new(function()
      return nil
    end)

    local success, result = pcall(get_latest_selection_handler, {})
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.success).to_be_false()
    expect(parsed_result.message).to_be("No selection available")
    assert.spy(mock_selection_module.get_latest_selection).was_called()
  end)

  it("should return the selection data if available", function()
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

    local success, result = pcall(get_latest_selection_handler, {})
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    assert.are.same(mock_sel_data, parsed_result)
    assert.spy(mock_selection_module.get_latest_selection).was_called()
  end)

  it("should handle pcall failure when requiring selection module", function()
    -- Simulate require failing
    package.loaded["claudecode.selection"] = nil
    local original_require = _G.require
    _G.require = function(mod_name)
      if mod_name == "claudecode.selection" then
        error("Simulated require failure for claudecode.selection")
      end
      return original_require(mod_name)
    end

    local success, err = pcall(get_latest_selection_handler, {})
    _G.require = original_require -- Restore original require

    expect(success).to_be_false()
    expect(err).to_be_table()
    expect(err.code).to_be(-32000)
    expect(err.message).to_be("Internal server error")
    expect(err.data).to_be("Failed to load selection module")
  end)
end)
