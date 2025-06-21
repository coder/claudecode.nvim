require("tests.busted_setup") -- Ensure test helpers are loaded

describe("Tool: save_document", function()
  local save_document_handler

  before_each(function()
    -- Clear module cache first
    package.loaded["claudecode.tools.save_document"] = nil

    -- Setup mocks and spies BEFORE requiring the module
    _G.vim = _G.vim or {}
    _G.vim.fn = _G.vim.fn or {}
    _G.vim.api = _G.vim.api or {}
    _G.vim.cmd_history = {} -- To track vim.cmd calls

    _G.vim.fn.bufnr = spy.new(function(filePath)
      if filePath == "/path/to/saveable_file.lua" then
        return 1
      end
      return -1 -- File not open
    end)

    _G.vim.api.nvim_buf_call = spy.new(function(bufnr, callback)
      if bufnr == 1 then
        callback() -- Execute the callback which should call vim.cmd("write")
      else
        error("nvim_buf_call called with unexpected bufnr: " .. tostring(bufnr))
      end
    end)

    _G.vim.cmd = spy.new(function(command)
      table.insert(_G.vim.cmd_history, command)
    end)

    -- Mock vim.json.encode
    _G.vim.json = _G.vim.json or {}
    _G.vim.json.encode = spy.new(function(data, opts)
      return require("tests.busted_setup").json_encode(data)
    end)

    -- Now require the module, it will pick up the spied functions
    save_document_handler = require("claudecode.tools.save_document").handler
  end)

  after_each(function()
    package.loaded["claudecode.tools.save_document"] = nil
    _G.vim.fn.bufnr = nil
    _G.vim.api.nvim_buf_call = nil
    _G.vim.cmd = nil
    _G.vim.cmd_history = nil
    _G.vim.json.encode = nil
  end)

  it("should error if filePath parameter is missing", function()
    local success, err = pcall(save_document_handler, {})
    expect(success).to_be_false()
    expect(err).to_be_table()
    expect(err.code).to_be(-32602)
    assert_contains(err.data, "Missing filePath parameter")
  end)

  it("should return success=false if file is not open in editor", function()
    local params = { filePath = "/path/to/non_open_file.py" }
    local success, result = pcall(save_document_handler, params)
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

  it("should call nvim_buf_call and vim.cmd('write') on success", function()
    local params = { filePath = "/path/to/saveable_file.lua" }
    -- Get a reference to the spy *before* calling the handler
    -- local nvim_buf_call_spy = _G.vim.api.nvim_buf_call -- Not needed before handler call

    local success, result = pcall(save_document_handler, params)

    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.success).to_be_true()
    expect(parsed_result.saved).to_be_true()
    expect(parsed_result.filePath).to_be("/path/to/saveable_file.lua")
    expect(parsed_result.message).to_be("Document saved successfully")

    assert.spy(_G.vim.fn.bufnr).was_called_with("/path/to/saveable_file.lua")
    -- Get the spy object for assertion using assert.spy()
    -- _G.vim.api.nvim_buf_call should be the spy set in before_each
    -- _G.vim.api.nvim_buf_call is the actual spy object from spy.new()
    -- It has .call_count and .calls fields directly.
    -- assert.spy() returns a wrapper for chained assertions, not for direct field access.
    local actual_nvim_buf_call_spy = _G.vim.api.nvim_buf_call -- This is the original spy
    -- Add a check to see what _G.vim.api.nvim_buf_call actually is at this point
    if type(actual_nvim_buf_call_spy) ~= "table" then
      print("ERROR: actual_nvim_buf_call_spy is not a table. Value: " .. tostring(actual_nvim_buf_call_spy))
    end
    assert.is_table(actual_nvim_buf_call_spy, "Spy object _G.vim.api.nvim_buf_call should be a table")
    -- Check for typical spy methods/fields
    assert.is_function(actual_nvim_buf_call_spy.clear, "Spy should have a .clear method")
    assert.is_function(actual_nvim_buf_call_spy.called, "Spy should have a .called method (property-style)")
    assert.is_not_nil(actual_nvim_buf_call_spy.calls, "Spy should have a .calls table")
    -- Use Luassert's spy assertion methods
    assert.spy(actual_nvim_buf_call_spy).was_called(1)
    -- assert.spy(actual_nvim_buf_call_spy).was_called_with(1, spy.any) -- This seems to be problematic with spy.any for functions
    -- If was_called_with passes, we can then inspect the specific call's arguments if needed,
    -- but often was_called_with(..., spy.any) is sufficient for function arguments.
    -- For demonstration, let's keep the direct check for the callback type from the spy's internal .calls table
    assert.is_not_nil(actual_nvim_buf_call_spy.calls[1], "Spy's first call record (calls[1]) should not be nil")
    local call_args = actual_nvim_buf_call_spy.calls[1].vals -- Arguments are in .vals based on debug output
    assert.is_not_nil(call_args, "Spy's first call arguments (calls[1].args) should not be nil")

    assert.are.equal(1, call_args[1])
    assert.are.equal("function", type(call_args[2]))

    local cmd_history_len = #_G.vim.cmd_history
    local first_cmd = _G.vim.cmd_history[1]
    assert.are.equal(1, cmd_history_len)
    assert.are.equal("write", first_cmd)
  end)

  it("should return success=false if nvim_buf_call fails", function()
    _G.vim.api.nvim_buf_call = spy.new(function(bufnr, callback)
      error("Simulated nvim_buf_call failure")
    end)
    local params = { filePath = "/path/to/saveable_file.lua" }
    local success, result = pcall(save_document_handler, params)

    expect(success).to_be_true() -- No longer throws error, returns success=false
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(result.content[1]).to_be_table()
    expect(result.content[1].type).to_be("text")

    local parsed_result = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(parsed_result.success).to_be_false()
    assert_contains(parsed_result.message, "Failed to save file")
    expect(parsed_result.filePath).to_be("/path/to/saveable_file.lua")
  end)
end)
