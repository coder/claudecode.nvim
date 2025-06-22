-- luacheck: globals expect
require("tests.busted_setup")

describe("netrw integration", function()
  local integrations
  local mock_vim

  local function setup_mocks()
    package.loaded["claudecode.integrations"] = nil
    package.loaded["claudecode.logger"] = nil

    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
    }

    mock_vim = {
      fn = {
        exists = function(func_name)
          if func_name == "*netrw#Expose" or func_name == "*netrw#Call" then
            return 1
          end
          return 0
        end,
        call = function(func_name, args)
          if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
            return {} -- No marked files by default
          elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
            return "test_file.lua"
          elseif func_name == "netrw#Call" and args[1] == "NetrwFile" then
            return "/Users/test/project/test_file.lua"
          end
          return ""
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
      bo = { filetype = "netrw" },
    }

    _G.vim = mock_vim
  end

  before_each(function()
    setup_mocks()
    integrations = require("claudecode.integrations")
  end)

  describe("_get_netrw_selection", function()
    it("should get single file under cursor", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {} -- No marked files
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "main.lua"
        elseif func_name == "netrw#Call" and args[1] == "NetrwFile" then
          return "/Users/test/project/main.lua"
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/main.lua")
    end)

    it("should get directory under cursor", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {} -- No marked files
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "src"
        elseif func_name == "netrw#Call" and args[1] == "NetrwFile" then
          return "/Users/test/project/src"
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/src")
    end)

    it("should get marked files when available", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {
            "/Users/test/project/file1.lua",
            "/Users/test/project/file2.lua",
            "/Users/test/project/src/",
          }
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(3)
      expect(files[1]).to_be("/Users/test/project/file1.lua")
      expect(files[2]).to_be("/Users/test/project/file2.lua")
      expect(files[3]).to_be("/Users/test/project/src/")
    end)

    it("should prefer marked files over cursor selection", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return { "/Users/test/project/marked_file.lua" }
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "cursor_file.lua"
        elseif func_name == "netrw#Call" and args[1] == "NetrwFile" then
          return "/Users/test/project/cursor_file.lua"
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/marked_file.lua")
    end)

    it("should filter out invalid files from marked list", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {
            "/Users/test/project/valid_file.lua",
            "/Users/test/project/invalid_file.xyz", -- This won't pass filereadable/isdirectory
            "/Users/test/project/src/",
          }
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(2) -- Only valid_file.lua and src/
      expect(files[1]).to_be("/Users/test/project/valid_file.lua")
      expect(files[2]).to_be("/Users/test/project/src/")
    end)

    it("should handle empty word under cursor", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {} -- No marked files
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "" -- Empty word
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be("Failed to get path from netrw")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle invalid file path", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {} -- No marked files
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "invalid_file"
        elseif func_name == "netrw#Call" and args[1] == "NetrwFile" then
          return "/Users/test/project/invalid_file"
        end
        return ""
      end

      mock_vim.fn.filereadable = function()
        return 0 -- File not readable
      end
      mock_vim.fn.isdirectory = function()
        return 0 -- Not a directory
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be("Invalid file or directory path: /Users/test/project/invalid_file")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle netrw function not available", function()
      mock_vim.fn.exists = function()
        return 0 -- Functions not available
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be("Failed to get path from netrw")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle pcall errors gracefully", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" then
          error("netrw#Expose failed")
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be("Failed to get path from netrw")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle mixed valid and invalid marked files", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {
            "/Users/test/project/valid1.lua",
            "/nonexistent/invalid.txt",
            "/Users/test/project/src/",
            "/another/invalid/path",
          }
        end
        return ""
      end

      mock_vim.fn.filereadable = function(path)
        return path:match("/Users/test/project/") and 1 or 0
      end

      mock_vim.fn.isdirectory = function(path)
        return path:match("/Users/test/project/src") and 1 or 0
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(2)
      expect(files[1]).to_be("/Users/test/project/valid1.lua")
      expect(files[2]).to_be("/Users/test/project/src/")
    end)
  end)

  describe("get_selected_files_from_tree", function()
    it("should detect netrw filetype and delegate to _get_netrw_selection", function()
      mock_vim.bo.filetype = "netrw"

      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {} -- No marked files
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "test.lua"
        elseif func_name == "netrw#Call" and args[1] == "NetrwFile" then
          return "/path/test.lua"
        end
        return ""
      end

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
