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
          if func_name == "*netrw#Call" or func_name == "*netrw#Expose" then
            return 1
          end
          return 0
        end,
        call = function(func_name, args)
          -- Default behavior - will be overridden in individual tests
          if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
            return {}
          elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
            return "test_file.lua"
          end
          return ""
        end,
        filereadable = function(path)
          if path:match("/nonexistent/") or path:match("invalid_file") then
            return 0
          elseif path:match("%.lua$") or path:match("%.txt$") or path:match("%.md$") then
            return 1
          end
          return 0
        end,
        isdirectory = function(path)
          if path:match("/nonexistent/") then
            return 0
          elseif path:match("/$") or path:match("/src$") or path:match("/docs$") or path:match("/subdir$") then
            return 1
          end
          return 0
        end,
        fnamemodify = function(path, modifier)
          if modifier == ":p" then
            if path:sub(1, 1) == "/" then
              return path
            else
              return "/test/project/" .. path
            end
          end
          return path
        end,
        getcwd = function()
          return "/test/project"
        end,
      },
      bo = { filetype = "netrw" },
      b = { netrw_curdir = "/test/project/subdir" },
      api = {
        nvim_get_current_buf = function()
          return 1
        end,
      },
    }

    _G.vim = mock_vim
  end

  before_each(function()
    setup_mocks()
    integrations = require("claudecode.integrations")
  end)

  describe("_get_netrw_selection", function()
    it("should return marked files when available", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {
            "/test/project/file1.lua",
            "/test/project/file2.txt",
            "/test/project/src/",
          }
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(3)
      expect(files[1]).to_be("/test/project/file1.lua")
      expect(files[2]).to_be("/test/project/file2.txt")
      expect(files[3]).to_be("/test/project/src/")
    end)

    it("should filter out invalid files from marked list", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {
            "/test/project/valid.lua",
            "/nonexistent/invalid.txt",
            "/test/project/src/",
            "/nonexistent/invalid_dir/",
          }
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(2) -- Only valid.lua and src/
      expect(files[1]).to_be("/test/project/valid.lua")
      expect(files[2]).to_be("/test/project/src/")
    end)

    it("should fall back to cursor selection when no marked files", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {}
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "cursor_file.lua"
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/subdir/cursor_file.lua")
    end)

    it("should handle directory under cursor", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {}
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "docs"
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/subdir/docs")
    end)

    it("should prefer marked files over cursor selection", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return { "/test/project/marked.lua" }
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "cursor.lua"
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/marked.lua")
    end)

    it("should use b:netrw_curdir for path resolution", function()
      mock_vim.b.netrw_curdir = "/custom/netrw/dir"

      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {}
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "relative.lua"
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/custom/netrw/dir/relative.lua")
    end)

    it("should return error when netrw functions are not available", function()
      mock_vim.fn.exists = function()
        return 0
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be("netrw not available")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle empty word from NetrwGetWord", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {}
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return ""
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be("Failed to get path from netrw")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle nil word from NetrwGetWord", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {}
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return nil
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be("Failed to get path from netrw")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle special navigation entries", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {}
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return ".."
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
          return {}
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "invalid_file"
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_match("Invalid file or directory path:")
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should handle netrw#Call pcall failure", function()
      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {}
        elseif func_name == "netrw#Call" then
          error("netrw#Call failed")
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
            "/test/project/valid1.lua",
            "/nonexistent/invalid1.txt",
            "/test/project/src/",
            "/nonexistent/invalid2/",
            "/test/project/valid2.md",
          }
        end
        return ""
      end

      local files, err = integrations._get_netrw_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(3)
      expect(files[1]).to_be("/test/project/valid1.lua")
      expect(files[2]).to_be("/test/project/src/")
      expect(files[3]).to_be("/test/project/valid2.md")
    end)
  end)

  describe("get_selected_files_from_tree", function()
    it("should detect netrw filetype and delegate to _get_netrw_selection", function()
      mock_vim.bo.filetype = "netrw"

      mock_vim.fn.call = function(func_name, args)
        if func_name == "netrw#Expose" and args[1] == "netrwmarkfilelist" then
          return {}
        elseif func_name == "netrw#Call" and args[1] == "NetrwGetWord" then
          return "integrated_test.lua"
        end
        return ""
      end

      local files, err = integrations.get_selected_files_from_tree()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/test/project/subdir/integrated_test.lua")
    end)

    it("should return error for unsupported filetype", function()
      mock_vim.bo.filetype = "unsupported"

      local files, err = integrations.get_selected_files_from_tree()

      expect(err).to_match("Not in a supported tree buffer")
      expect(files).to_be_nil()
    end)
  end)
end)
