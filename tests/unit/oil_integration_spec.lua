-- luacheck: globals expect
require("tests.busted_setup")

describe("oil.nvim integration", function()
  local integrations
  local mock_vim

  local function setup_mocks()
    package.loaded["claudecode.integrations"] = nil
    package.loaded["claudecode.visual_commands"] = nil
    package.loaded["claudecode.logger"] = nil

    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
    }

    mock_vim = {
      fn = {
        mode = function()
          return "n" -- Default to normal mode
        end,
        line = function(mark)
          if mark == "'<" then
            return 2
          elseif mark == "'>" then
            return 4
          end
          return 1
        end,
      },
      api = {
        nvim_get_current_buf = function()
          return 1
        end,
        nvim_win_get_cursor = function()
          return { 4, 0 }
        end,
        nvim_get_mode = function()
          return { mode = "n" }
        end,
      },
      bo = { filetype = "oil" },
    }

    _G.vim = mock_vim
  end

  before_each(function()
    setup_mocks()
    integrations = require("claudecode.integrations")
  end)

  describe("_get_oil_selection", function()
    it("should get single file under cursor in normal mode", function()
      local mock_oil = {
        get_cursor_entry = function()
          return { type = "file", name = "main.lua" }
        end,
        get_current_dir = function(bufnr)
          return "/Users/test/project/"
        end,
      }

      package.loaded["oil"] = mock_oil

      local files, err = integrations._get_oil_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/main.lua")
    end)

    it("should get directory under cursor in normal mode", function()
      local mock_oil = {
        get_cursor_entry = function()
          return { type = "directory", name = "src" }
        end,
        get_current_dir = function(bufnr)
          return "/Users/test/project/"
        end,
      }

      package.loaded["oil"] = mock_oil

      local files, err = integrations._get_oil_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/src/")
    end)

    it("should skip parent directory entries", function()
      local mock_oil = {
        get_cursor_entry = function()
          return { type = "directory", name = ".." }
        end,
        get_current_dir = function(bufnr)
          return "/Users/test/project/"
        end,
      }

      package.loaded["oil"] = mock_oil

      local files, err = integrations._get_oil_selection()

      expect(err).to_be("No file found under cursor")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle symbolic links", function()
      local mock_oil = {
        get_cursor_entry = function()
          return { type = "link", name = "linked_file.lua" }
        end,
        get_current_dir = function(bufnr)
          return "/Users/test/project/"
        end,
      }

      package.loaded["oil"] = mock_oil

      local files, err = integrations._get_oil_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/linked_file.lua")
    end)

    it("should handle visual mode selection", function()
      -- Mock visual mode
      mock_vim.fn.mode = function()
        return "V"
      end
      mock_vim.api.nvim_get_mode = function()
        return { mode = "V" }
      end

      -- Mock visual_commands module
      package.loaded["claudecode.visual_commands"] = {
        get_visual_range = function()
          return 2, 4 -- Lines 2 to 4
        end,
      }

      local line_entries = {
        [2] = { type = "file", name = "file1.lua" },
        [3] = { type = "directory", name = "src" },
        [4] = { type = "file", name = "file2.lua" },
      }

      local mock_oil = {
        get_current_dir = function(bufnr)
          return "/Users/test/project/"
        end,
        get_entry_on_line = function(bufnr, line)
          return line_entries[line]
        end,
      }

      package.loaded["oil"] = mock_oil

      local files, err = integrations._get_oil_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(3)
      expect(files[1]).to_be("/Users/test/project/file1.lua")
      expect(files[2]).to_be("/Users/test/project/src/")
      expect(files[3]).to_be("/Users/test/project/file2.lua")
    end)

    it("should handle errors gracefully", function()
      local mock_oil = {
        get_cursor_entry = function()
          error("Failed to get cursor entry")
        end,
      }

      package.loaded["oil"] = mock_oil

      local files, err = integrations._get_oil_selection()

      expect(err).to_be("Failed to get cursor entry")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle missing oil.nvim", function()
      package.loaded["oil"] = nil

      local files, err = integrations._get_oil_selection()

      expect(err).to_be("oil.nvim not available")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)
  end)

  describe("get_selected_files_from_tree", function()
    it("should detect oil filetype and delegate to _get_oil_selection", function()
      mock_vim.bo.filetype = "oil"

      local mock_oil = {
        get_cursor_entry = function()
          return { type = "file", name = "test.lua" }
        end,
        get_current_dir = function(bufnr)
          return "/path/"
        end,
      }

      package.loaded["oil"] = mock_oil

      local files, err = integrations.get_selected_files_from_tree()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/path/test.lua")
    end)
  end)
end)
