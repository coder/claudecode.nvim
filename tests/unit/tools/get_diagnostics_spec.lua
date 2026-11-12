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
      return require("tests.busted_setup").json_encode(obj)
    end)
    _G.vim.uri_from_fname = nil
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
    _G.vim.startswith = function(str, prefix)
      return str:sub(1, #prefix) == prefix
    end
  end)

  after_each(function()
    package.loaded["claudecode.tools.get_diagnostics"] = nil
    package.loaded["claudecode.logger"] = nil
    _G.vim.diagnostic.get = nil
    _G.vim.api.nvim_buf_get_name = nil
    _G.vim.json.encode = nil
    _G.vim.fn.bufnr = nil
    _G.vim.uri_to_fname = nil
    _G.vim.uri_from_fname = nil
    _G.vim.startswith = nil
    -- Note: We don't nullify _G.vim.lsp or _G.vim.diagnostic entirely
    -- as they are checked for existence.
  end)

  it("should return an empty diagnostic file list if no diagnostics are found", function()
    local success, result = pcall(get_diagnostics_handler, {})
    expect(success).to_be_true()
    expect(result).to_be_table()
    expect(result.content).to_be_table()
    expect(#result.content).to_be(1)
    expect(result.content[1].type).to_be("text")

    local diagnostic_files = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(#diagnostic_files).to_be(0)
    assert.spy(_G.vim.diagnostic.get).was_called_with(nil)
  end)

  it("should return diagnostics in Claude Code DiagnosticFile format", function()
    local mock_diagnostics = {
      {
        bufnr = 1,
        lnum = 10,
        col = 5,
        end_lnum = 10,
        end_col = 12,
        severity = 1,
        message = "Error message 1",
        source = "linter1",
        code = 123,
      },
      { bufnr = 2, lnum = 20, col = 15, severity = 2, message = "Warning message 2", source = "linter2" },
    }
    _G.vim.diagnostic.get = spy.new(function()
      return mock_diagnostics
    end)

    local success, result = pcall(get_diagnostics_handler, {})
    expect(success).to_be_true()
    expect(result.content).to_be_table()
    expect(#result.content).to_be(1)
    expect(result.content[1].type).to_be("text")
    assert.spy(_G.vim.json.encode).was_called(1)

    local diagnostic_files = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(#diagnostic_files).to_be(2)

    expect(diagnostic_files[1].uri).to_be("file:///path/to/file_for_buf_1.lua")
    expect(#diagnostic_files[1].diagnostics).to_be(1)
    expect(diagnostic_files[1].diagnostics[1].message).to_be("Error message 1")
    expect(diagnostic_files[1].diagnostics[1].severity).to_be("Error")
    expect(diagnostic_files[1].diagnostics[1].range.start.line).to_be(10)
    expect(diagnostic_files[1].diagnostics[1].range.start.character).to_be(5)
    expect(diagnostic_files[1].diagnostics[1].range["end"].line).to_be(10)
    expect(diagnostic_files[1].diagnostics[1].range["end"].character).to_be(12)
    expect(diagnostic_files[1].diagnostics[1].source).to_be("linter1")
    expect(diagnostic_files[1].diagnostics[1].code).to_be("123")

    expect(diagnostic_files[2].uri).to_be("file:///path/to/file_for_buf_2.lua")
    expect(diagnostic_files[2].diagnostics[1].severity).to_be("Warning")

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

    local diagnostic_files = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(#diagnostic_files).to_be(1)
    expect(diagnostic_files[1].uri).to_be("file:///path/to/file1.lua")
    expect(#diagnostic_files[1].diagnostics).to_be(1)
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

  it("should check uri before it checks that diagnostics are available", function()
    _G.vim.diagnostic.get = nil
    local success, err = pcall(get_diagnostics_handler, { uri = true })
    expect(success).to_be_false()
    expect(err.code).to_be(-32602)
    expect(err.data).to_be("Invalid parameter: uri (a string is required)")
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

    local diagnostic_files = require("tests.busted_setup").json_decode(result.content[1].text)
    expect(#diagnostic_files).to_be(1)
    expect(diagnostic_files[1].uri).to_be("file:///test/file.lua")
    expect(diagnostic_files[1].diagnostics[1].message).to_be("Error in file1")

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

  for _, case in ipairs({
    { label = "false", value = false },
    { label = "true", value = true },
    { label = "a number", value = 5 },
    { label = "a table", value = { "file:///test/file.lua" } },
  }) do
    it("should error if uri is " .. case.label .. " and not a string", function()
      local success, err = pcall(get_diagnostics_handler, { uri = case.value })
      expect(success).to_be_false()
      expect(err).to_be_table()
      expect(err.code).to_be(-32602)
      expect(err.data).to_be("Invalid parameter: uri (a string is required)")
      assert.spy(_G.vim.diagnostic.get).was_not_called()
    end)
  end
  describe("DiagnosticFile entries", function()
    -- A diagnostic as vim.diagnostic.get returns it: vim.diagnostic.set fills in the buffer number, the severity
    -- (Error) and the end position (the start), and it requires `lnum` (and `col` on Neovim 0.8). Only the message,
    -- the code and the source can be missing (`evidence/p2r1/probe-unreachable-*.txt`).
    local function diagnostic(fields)
      local filled = { bufnr = 1, lnum = 0, col = 0, end_lnum = 0, end_col = 0, severity = 1 }
      for key, value in pairs(fields) do
        filled[key] = value
      end
      return filled
    end

    before_each(function()
      -- vim.uri_from_fname exists on Neovim 0.8 and later. It percent-encodes a path as RFC 3986 says, with lowercase
      -- hex digits (`evidence/p2r2/probe-p2r2-*.txt`, F3).
      _G.vim.uri_from_fname = function(path)
        return "file://"
          .. path:gsub("[^%w/._~:@!$&'()*+,;=-]", function(char)
            return string.format("%%%02x", char:byte())
          end)
      end
    end)

    local function files_for(diagnostics, params)
      _G.vim.diagnostic.get = spy.new(function()
        return diagnostics
      end)
      local success, result = pcall(get_diagnostics_handler, params or {})
      expect(success).to_be_true()
      return require("tests.busted_setup").json_decode(result.content[1].text)
    end

    it("groups the diagnostics of one file into one entry, in order, and keeps the entries in order", function()
      local files = files_for({
        diagnostic({ bufnr = 1, lnum = 1, severity = 1, message = "one" }),
        diagnostic({ bufnr = 2, lnum = 2, severity = 2, message = "two" }),
        diagnostic({ bufnr = 1, lnum = 3, severity = 3, message = "three" }),
      })

      expect(#files).to_be(2)
      expect(files[1].uri).to_be("file:///path/to/file_for_buf_1.lua")
      expect(files[1].diagnostics[1].message).to_be("one")
      expect(files[1].diagnostics[2].message).to_be("three")
      expect(files[2].uri).to_be("file:///path/to/file_for_buf_2.lua")
      expect(#files[2].diagnostics).to_be(1)
    end)

    it("names severities 1 to 4 and calls any other number Info", function()
      -- Neovim 0.12 keeps a severity of 9. On Neovim 0.8 the default signs handler raises E155 for it, and with
      -- `signs = false` 0.8 keeps it too (`evidence/p2r2/probe-p2r2-*.txt`, F2a and F2b).
      local files = files_for({
        diagnostic({ severity = 1 }),
        diagnostic({ severity = 2 }),
        diagnostic({ severity = 3 }),
        diagnostic({ severity = 4 }),
        diagnostic({ severity = 9 }),
      })

      local severities = {}
      for _, diagnostic_entry in ipairs(files[1].diagnostics) do
        table.insert(severities, diagnostic_entry.severity)
      end
      assert.are.same({ "Error", "Warning", "Info", "Hint", "Info" }, severities)
    end)

    it("copies the start and the end of a range, which can span lines", function()
      local files = files_for({
        diagnostic({ lnum = 4, col = 2, end_lnum = 6, end_col = 9 }),
        diagnostic({ lnum = 7, col = 1, end_lnum = 7, end_col = 1 }),
      })

      local ranges = {}
      for _, diagnostic_entry in ipairs(files[1].diagnostics) do
        table.insert(ranges, diagnostic_entry.range)
      end
      assert.are.same({ line = 4, character = 2 }, ranges[1].start)
      assert.are.same({ line = 6, character = 9 }, ranges[1]["end"])
      assert.are.same({ line = 7, character = 1 }, ranges[2].start)
      assert.are.same({ line = 7, character = 1 }, ranges[2]["end"])
    end)

    it("sends an empty message for a diagnostic without one, and no code or source", function()
      local entry = files_for({ diagnostic({}) })[1].diagnostics[1]

      expect(entry.message).to_be("")
      expect(entry.code).to_be_nil()
      expect(entry.source).to_be_nil()
    end)

    -- Neovim finds a buffer by its name, so a requested path never finds a buffer with no name. Only a special name
    -- of bufnr() can: "%" is the current buffer. The handler then answers the special name itself as a file URI. That
    -- is today's answer on Neovim 0.12.3 and v0.8.0 (`evidence/p2r2/probe-p2r2-*.txt`, F1c).
    it("answers file://%25 for the request % with an unnamed buffer (pins today's answer)", function()
      _G.vim.fn.bufnr = spy.new(function()
        return 1
      end)
      _G.vim.api.nvim_buf_get_name = spy.new(function()
        return ""
      end)

      local files = files_for({ diagnostic({ message = "unnamed" }) }, { uri = "%" })

      expect(#files).to_be(1)
      expect(files[1].uri).to_be("file://%25")
      expect(#files[1].diagnostics).to_be(1)
    end)

    it("writes the URI of a file name with a space and a hash percent-encoded", function()
      _G.vim.api.nvim_buf_get_name = spy.new(function()
        return "/path/to/a b#c.lua"
      end)

      local files = files_for({ diagnostic({ message = "encoded" }) })

      expect(files[1].uri).to_be("file:///path/to/a%20b%23c.lua")
    end)

    it("takes a URI without a file scheme as the path", function()
      -- The buffer that bufnr finds has the name that Neovim gives it: an absolute path.
      _G.vim.fn.bufnr = spy.new(function(path)
        return path == "relative.lua" and 3 or -1
      end)
      _G.vim.api.nvim_buf_get_name = spy.new(function()
        return "/work/relative.lua"
      end)

      local files = files_for({ diagnostic({ bufnr = 3, message = "relative" }) }, { uri = "relative.lua" })

      assert.spy(_G.vim.fn.bufnr).was_called_with("relative.lua")
      expect(files[1].uri).to_be("file:///work/relative.lua")
      assert.spy(_G.vim.uri_to_fname).was_not_called()
    end)
  end)
end)
