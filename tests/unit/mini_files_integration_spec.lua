-- luacheck: globals expect
require("tests.busted_setup")

describe("mini.files integration", function()
  local integrations
  local mock_vim

  local function setup_mocks()
    package.loaded["claudecode.integrations"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.visual_commands"] = nil

    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
    }

    -- Mock visual_commands
    package.loaded["claudecode.visual_commands"] = {
      get_visual_range = function()
        return 1, 3 -- Return lines 1-3 by default
      end,
    }

    mock_vim = {
      fn = {
        mode = function()
          return "n" -- Normal mode by default
        end,
        filereadable = function(path)
          if path:match("%.lua$") or path:match("%.txt$") then
            return 1
          end
          return 0
        end,
        isdirectory = function(path)
          if path:match("/$") or path:match("/src$") then
            return 1
          end
          return 0
        end,
      },
      bo = { filetype = "minifiles" },
    }

    _G.vim = mock_vim
  end

  before_each(function()
    setup_mocks()
    integrations = require("claudecode.integrations")
  end)

  describe("_get_mini_files_selection", function()
    it("should get single file under cursor", function()
      -- Mock mini.files module
      local mock_mini_files = {
        get_fs_entry = function()
          return { path = "/Users/test/project/main.lua" }
        end,
      }
      package.loaded["mini.files"] = mock_mini_files

      local files, err = integrations._get_mini_files_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/main.lua")
    end)

    it("should get directory under cursor", function()
      -- Mock mini.files module
      local mock_mini_files = {
        get_fs_entry = function()
          return { path = "/Users/test/project/src" }
        end,
      }
      package.loaded["mini.files"] = mock_mini_files

      local files, err = integrations._get_mini_files_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/src")
    end)

    it("should get multiple files in visual mode", function()
      mock_vim.fn.mode = function()
        return "V" -- Visual line mode
      end

      -- Mock mini.files module
      local mock_mini_files = {
        get_fs_entry = function(buf_id, line)
          if line == 1 then
            return { path = "/Users/test/project/file1.lua" }
          elseif line == 2 then
            return { path = "/Users/test/project/file2.lua" }
          elseif line == 3 then
            return { path = "/Users/test/project/src" }
          end
          return nil
        end,
      }
      package.loaded["mini.files"] = mock_mini_files

      local files, err = integrations._get_mini_files_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(3)
      expect(files[1]).to_be("/Users/test/project/file1.lua")
      expect(files[2]).to_be("/Users/test/project/file2.lua")
      expect(files[3]).to_be("/Users/test/project/src")
    end)

    it("should filter out invalid files in visual mode", function()
      mock_vim.fn.mode = function()
        return "V" -- Visual line mode
      end

      -- Mock mini.files module
      local mock_mini_files = {
        get_fs_entry = function(buf_id, line)
          if line == 1 then
            return { path = "/Users/test/project/valid.lua" }
          elseif line == 2 then
            return { path = "/Users/test/project/invalid.xyz" } -- Won't pass filereadable/isdirectory
          elseif line == 3 then
            return { path = "/Users/test/project/src" }
          end
          return nil
        end,
      }
      package.loaded["mini.files"] = mock_mini_files

      local files, err = integrations._get_mini_files_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(2) -- Only valid.lua and src
      expect(files[1]).to_be("/Users/test/project/valid.lua")
      expect(files[2]).to_be("/Users/test/project/src")
    end)

    it("should handle empty entry under cursor", function()
      -- Mock mini.files module
      local mock_mini_files = {
        get_fs_entry = function()
          return nil -- No entry
        end,
      }
      package.loaded["mini.files"] = mock_mini_files

      local files, err = integrations._get_mini_files_selection()

      expect(err).to_be("Failed to get entry from mini.files")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle entry with empty path", function()
      -- Mock mini.files module
      local mock_mini_files = {
        get_fs_entry = function()
          return { path = "" } -- Empty path
        end,
      }
      package.loaded["mini.files"] = mock_mini_files

      local files, err = integrations._get_mini_files_selection()

      expect(err).to_be("No file found under cursor")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle invalid file path", function()
      -- Mock mini.files module
      local mock_mini_files = {
        get_fs_entry = function()
          return { path = "/Users/test/project/invalid_file" }
        end,
      }
      package.loaded["mini.files"] = mock_mini_files

      mock_vim.fn.filereadable = function()
        return 0 -- File not readable
      end
      mock_vim.fn.isdirectory = function()
        return 0 -- Not a directory
      end

      local files, err = integrations._get_mini_files_selection()

      expect(err).to_be("Invalid file or directory path: /Users/test/project/invalid_file")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle mini.files not available", function()
      -- Don't mock mini.files module (will cause require to fail)
      package.loaded["mini.files"] = nil

      local files, err = integrations._get_mini_files_selection()

      expect(err).to_be("mini.files not available")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle pcall errors gracefully", function()
      -- Mock mini.files module that throws errors
      local mock_mini_files = {
        get_fs_entry = function()
          error("mini.files get_fs_entry failed")
        end,
      }
      package.loaded["mini.files"] = mock_mini_files

      local files, err = integrations._get_mini_files_selection()

      expect(err).to_be("Failed to get entry from mini.files")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle visual mode with no valid entries", function()
      mock_vim.fn.mode = function()
        return "V" -- Visual line mode
      end

      -- Mock mini.files module
      local mock_mini_files = {
        get_fs_entry = function(buf_id, line)
          return nil -- No entries
        end,
      }
      package.loaded["mini.files"] = mock_mini_files

      local files, err = integrations._get_mini_files_selection()

      expect(err).to_be("No file found under cursor")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)
  end)

  describe("get_selected_files_from_tree", function()
    it("should detect minifiles filetype and delegate to _get_mini_files_selection", function()
      mock_vim.bo.filetype = "minifiles"

      -- Mock mini.files module
      local mock_mini_files = {
        get_fs_entry = function()
          return { path = "/path/test.lua" }
        end,
      }
      package.loaded["mini.files"] = mock_mini_files

      local files, err = integrations.get_selected_files_from_tree()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/path/test.lua")
    end)

    it("should return error for unsupported filetype", function()
      mock_vim.bo.filetype = "unsupported"

      local files, err = integrations.get_selected_files_from_tree()

      assert_contains(err, "Not in a supported tree buffer")
      expect(files).to_be_nil()
    end)
  end)
end)