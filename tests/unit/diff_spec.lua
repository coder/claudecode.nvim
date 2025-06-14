-- luacheck: globals expect
require("tests.busted_setup")

describe("Diff Module", function()
  local diff

  local original_vim_functions = {}

  local function setup()
    package.loaded["claudecode.diff"] = nil
    package.loaded["claudecode.config"] = nil

    assert(_G.vim, "Global vim mock not initialized by busted_setup.lua")
    assert(_G.vim.fn, "Global vim.fn mock not initialized")

    -- For this spec, the global mock (which now includes stdpath) should be largely sufficient.
    -- The local mock_vim that was missing stdpath is removed.

    diff = require("claudecode.diff")
  end

  local function teardown()
    for path, func in pairs(original_vim_functions) do
      local parts = {}
      for part in string.gmatch(path, "[^%.]+") do
        table.insert(parts, part)
      end
      local obj = _G.vim
      for i = 1, #parts - 1 do
        obj = obj[parts[i]]
      end
      obj[parts[#parts]] = func
    end
    original_vim_functions = {}

    if original_vim_functions["cmd"] then
      _G.vim.cmd = original_vim_functions["cmd"]
      original_vim_functions["cmd"] = nil
    end

    -- _G.vim itself is managed by busted_setup.lua
  end

  before_each(function()
    setup()
  end)

  after_each(function()
    teardown()
  end)

  describe("Temporary File Management (via Native Diff)", function()
    it("should create temporary files with correct content through native diff", function()
      local test_content = "This is test content\nLine 2\nLine 3"
      local old_file_path = "/path/to/old.lua"
      local new_file_path = "/path/to/new.lua"

      local mock_file = {
        write = function() end,
        close = function() end,
      }
      local old_io_open = io.open
      rawset(io, "open", function()
        return mock_file
      end)

      local result = diff._open_native_diff(old_file_path, new_file_path, test_content, "Test Diff")

      expect(result).to_be_table()
      expect(result.success).to_be_true()
      expect(result.temp_file).to_be_string()
      expect(result.temp_file:find("claudecode_diff", 1, true)).not_to_be_nil()
      local expected_suffix = vim.fn.fnamemodify(new_file_path, ":t") .. ".new"
      expect(result.temp_file:find(expected_suffix, 1, true)).not_to_be_nil()

      rawset(io, "open", old_io_open)
    end)

    it("should handle file creation errors in native diff", function()
      local test_content = "test"
      local old_file_path = "/path/to/old.lua"
      local new_file_path = "/path/to/new.lua"

      local old_io_open = io.open
      rawset(io, "open", function()
        return nil
      end)

      local result = diff._open_native_diff(old_file_path, new_file_path, test_content, "Test Diff")

      expect(result).to_be_table()
      expect(result.success).to_be_false()
      expect(result.error).to_be_string()
      expect(result.error:find("Failed to create temporary file", 1, true)).not_to_be_nil()
      expect(result.temp_file).to_be_nil() -- Ensure no temp_file is created on failure

      rawset(io, "open", old_io_open)
    end)
  end)

  describe("Native Diff Implementation", function()
    it("should create diff with correct parameters", function()
      diff.setup({
        diff_opts = {
          vertical_split = true,
          show_diff_stats = false,
          auto_close_on_accept = true,
        },
      })

      local commands = {}
      if _G.vim and rawget(original_vim_functions, "cmd") == nil then
        original_vim_functions["cmd"] = _G.vim.cmd
      end
      _G.vim.cmd = function(cmd)
        table.insert(commands, cmd)
      end

      local mock_file = {
        write = function() end,
        close = function() end,
      }
      local old_io_open = io.open
      rawset(io, "open", function()
        return mock_file
      end)

      local result = diff._open_native_diff("/path/to/old.lua", "/path/to/new.lua", "new content here", "Test Diff")

      expect(result.success).to_be_true()
      expect(result.provider).to_be("native")
      expect(result.tab_name).to_be("Test Diff")

      local found_vsplit = false
      local found_diffthis = false
      local found_edit = false

      for _, cmd in ipairs(commands) do
        if cmd:find("vsplit", 1, true) then
          found_vsplit = true
        end
        if cmd:find("diffthis", 1, true) then
          found_diffthis = true
        end
        if cmd:find("edit", 1, true) then
          found_edit = true
        end
      end

      expect(found_vsplit).to_be_true()
      expect(found_diffthis).to_be_true()
      expect(found_edit).to_be_true()

      rawset(io, "open", old_io_open)
    end)

    it("should use horizontal split when configured", function()
      diff.setup({
        diff_opts = {
          vertical_split = false,
          show_diff_stats = false,
          auto_close_on_accept = true,
        },
      })

      local commands = {}
      if _G.vim and rawget(original_vim_functions, "cmd") == nil then
        original_vim_functions["cmd"] = _G.vim.cmd
      end
      _G.vim.cmd = function(cmd)
        table.insert(commands, cmd)
      end

      local mock_file = {
        write = function() end,
        close = function() end,
      }
      local old_io_open = io.open
      rawset(io, "open", function()
        return mock_file
      end)

      local result = diff._open_native_diff("/path/to/old.lua", "/path/to/new.lua", "new content here", "Test Diff")

      expect(result.success).to_be_true()
      local found_split = false
      local found_vertical_split = false

      for _, cmd in ipairs(commands) do
        if cmd:find("split", 1, true) and not cmd:find("vertical split", 1, true) then
          found_split = true
        end
        if cmd:find("vertical split", 1, true) then
          found_vertical_split = true
        end
      end

      expect(found_split).to_be_true()
      expect(found_vertical_split).to_be_false()

      rawset(io, "open", old_io_open)
    end)

    it("should handle temporary file creation errors", function()
      diff.setup({})

      local old_io_open = io.open
      rawset(io, "open", function()
        return nil
      end)

      local result = diff._open_native_diff("/path/to/old.lua", "/path/to/new.lua", "new content here", "Test Diff")

      expect(result.success).to_be_false()
      expect(result.error).to_be_string()
      expect(result.error:find("Failed to create temporary file", 1, true)).not_to_be_nil()

      rawset(io, "open", old_io_open)
    end)
  end)

  describe("Filetype Propagation", function()
    it("should propagate original filetype to proposed buffer", function()
      diff.setup({})

      -- Spy on nvim_set_option_value
      spy.on(_G.vim.api, "nvim_set_option_value")

      local mock_file = {
        write = function() end,
        close = function() end,
      }
      local old_io_open = io.open
      rawset(io, "open", function()
        return mock_file
      end)

      local result = diff._open_native_diff("/tmp/test.ts", "/tmp/test.ts", "-- new", "Propagate FT")
      expect(result.success).to_be_true()

      -- Verify spy called with filetype typescript
      local calls = _G.vim.api.nvim_set_option_value.calls or {}
      local found = false
      for _, c in ipairs(calls) do
        if c.vals[1] == "filetype" and c.vals[2] == "typescript" then
          found = true
          break
        end
      end
      expect(found).to_be_true()

      rawset(io, "open", old_io_open)
    end)
  end)

  describe("Open Diff Function", function()
    it("should use native provider", function()
      diff.setup({})

      local native_called = false
      diff._open_native_diff = function(old_path, new_path, content, tab_name)
        native_called = true
        return {
          success = true,
          provider = "native",
          tab_name = tab_name,
          temp_file = "/mock/temp/file.new",
        }
      end

      local result = diff.open_diff("/path/to/old.lua", "/path/to/new.lua", "new content", "Test Diff")

      expect(native_called).to_be_true()
      expect(result.provider).to_be("native")
      expect(result.success).to_be_true()
    end)
  end)

  teardown()
end)
