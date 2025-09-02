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
      api = {
        nvim_get_current_buf = function()
          return 1 -- Mock buffer ID
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
        get_fs_entry = function(buf_id)
          -- Verify buffer ID is passed correctly
          if buf_id ~= 1 then
            return nil
          end
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
        get_fs_entry = function(buf_id)
          -- Verify buffer ID is passed correctly
          if buf_id ~= 1 then
            return nil
          end
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

    it("should handle mini.files buffer path format", function()
      -- Mock mini.files module that returns buffer-style paths
      local mock_mini_files = {
        get_fs_entry = function(buf_id)
          if buf_id ~= 1 then
            return nil
          end
          return { path = "minifiles://42//Users/test/project/buffer_file.lua" }
        end,
      }
      package.loaded["mini.files"] = mock_mini_files

      local files, err = integrations._get_mini_files_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/buffer_file.lua")
    end)

    it("should handle various mini.files buffer path formats", function()
      -- Test different buffer path formats that could occur
      local test_cases = {
        { input = "minifiles://42/Users/test/file.lua", expected = "Users/test/file.lua" },
        { input = "minifiles://42//Users/test/file.lua", expected = "/Users/test/file.lua" },
        { input = "minifiles://123///Users/test/file.lua", expected = "//Users/test/file.lua" },
        { input = "/Users/test/normal_path.lua", expected = "/Users/test/normal_path.lua" },
      }

      for i, test_case in ipairs(test_cases) do
        local mock_mini_files = {
          get_fs_entry = function(buf_id)
            if buf_id ~= 1 then
              return nil
            end
            return { path = test_case.input }
          end,
        }
        package.loaded["mini.files"] = mock_mini_files

        local files, err = integrations._get_mini_files_selection()

        expect(err).to_be_nil()
        expect(files).to_be_table()
        expect(#files).to_be(1)
        expect(files[1]).to_be(test_case.expected)
      end
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
