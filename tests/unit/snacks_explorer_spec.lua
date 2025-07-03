local integrations = require("claudecode.integrations")

describe("snacks.explorer integration", function()
  before_each(function()
    require("tests.helpers.setup")()
  end)

  after_each(function()
    -- No cleanup needed
  end)

  describe("_get_snacks_explorer_selection", function()
    it("should return error when snacks.nvim is not available", function()
      -- Mock require to fail for snacks
      local original_require = _G.require
      _G.require = function(module)
        if module == "snacks" then
          error("Module not found")
        end
        return original_require(module)
      end

      local files, err = integrations._get_snacks_explorer_selection()
      assert.are.same({}, files)
      assert.equals("snacks.nvim not available", err)

      -- Restore original require
      _G.require = original_require
    end)

    it("should return error when no explorer picker is active", function()
      -- Mock snacks module
      local mock_snacks = {
        picker = {
          get = function()
            return {}
          end,
        },
      }

      package.loaded["snacks"] = mock_snacks

      local files, err = integrations._get_snacks_explorer_selection()
      assert.are.same({}, files)
      assert.equals("No active snacks.explorer found", err)

      package.loaded["snacks"] = nil
    end)

    it("should return selected files from snacks.explorer", function()
      -- Mock snacks module with explorer picker
      local mock_explorer = {
        selected = function(self, opts)
          return {
            { file = "/path/to/file1.lua" },
            { file = "/path/to/file2.lua" },
          }
        end,
        current = function(self, opts)
          return { file = "/path/to/current.lua" }
        end,
      }

      local mock_snacks = {
        picker = {
          get = function(opts)
            if opts.source == "explorer" then
              return { mock_explorer }
            end
            return {}
          end,
        },
      }

      package.loaded["snacks"] = mock_snacks

      local files, err = integrations._get_snacks_explorer_selection()
      assert.is_nil(err)
      assert.are.same({ "/path/to/file1.lua", "/path/to/file2.lua" }, files)

      package.loaded["snacks"] = nil
    end)

    it("should fall back to current file when no selection", function()
      -- Mock snacks module with explorer picker
      local mock_explorer = {
        selected = function(self, opts)
          return {}
        end,
        current = function(self, opts)
          return { file = "/path/to/current.lua" }
        end,
      }

      local mock_snacks = {
        picker = {
          get = function(opts)
            if opts.source == "explorer" then
              return { mock_explorer }
            end
            return {}
          end,
        },
      }

      package.loaded["snacks"] = mock_snacks

      local files, err = integrations._get_snacks_explorer_selection()
      assert.is_nil(err)
      assert.are.same({ "/path/to/current.lua" }, files)

      package.loaded["snacks"] = nil
    end)

    it("should handle empty file paths", function()
      -- Mock snacks module with empty file paths
      local mock_explorer = {
        selected = function(self, opts)
          return {
            { file = "" },
            { file = "/valid/path.lua" },
            { file = nil },
          }
        end,
        current = function(self, opts)
          return { file = "" }
        end,
      }

      local mock_snacks = {
        picker = {
          get = function(opts)
            if opts.source == "explorer" then
              return { mock_explorer }
            end
            return {}
          end,
        },
      }

      package.loaded["snacks"] = mock_snacks

      local files, err = integrations._get_snacks_explorer_selection()
      assert.is_nil(err)
      assert.are.same({ "/valid/path.lua" }, files)

      package.loaded["snacks"] = nil
    end)

    it("should try alternative fields for file path", function()
      -- Mock snacks module with different field names
      local mock_explorer = {
        selected = function(self, opts)
          return {
            { path = "/path/from/path.lua" },
            { item = { file = "/path/from/item.file.lua" } },
            { item = { path = "/path/from/item.path.lua" } },
          }
        end,
        current = function(self, opts)
          return { path = "/current/from/path.lua" }
        end,
      }

      local mock_snacks = {
        picker = {
          get = function(opts)
            if opts.source == "explorer" then
              return { mock_explorer }
            end
            return {}
          end,
        },
      }

      package.loaded["snacks"] = mock_snacks

      local files, err = integrations._get_snacks_explorer_selection()
      assert.is_nil(err)
      assert.are.same({
        "/path/from/path.lua",
        "/path/from/item.file.lua",
        "/path/from/item.path.lua",
      }, files)

      package.loaded["snacks"] = nil
    end)

    it("should handle visual mode selection with range parameters", function()
      -- Mock snacks module with explorer picker that has list
      local mock_list = {
        row2idx = function(self, row)
          return row -- Simple 1:1 mapping for test
        end,
        get = function(self, idx)
          local items = {
            [1] = { file = "/path/to/file1.lua" },
            [2] = { file = "/path/to/file2.lua" },
            [3] = { file = "/path/to/file3.lua" },
            [4] = { file = "/path/to/file4.lua" },
            [5] = { file = "/path/to/file5.lua" },
          }
          return items[idx]
        end,
      }

      local mock_explorer = {
        list = mock_list,
        selected = function(self, opts)
          return {} -- No marked selection
        end,
        current = function(self, opts)
          return { file = "/path/to/current.lua" }
        end,
      }

      local mock_snacks = {
        picker = {
          get = function(opts)
            if opts.source == "explorer" then
              return { mock_explorer }
            end
            return {}
          end,
        },
      }

      package.loaded["snacks"] = mock_snacks

      -- Test visual selection from lines 2 to 4
      local files, err = integrations._get_snacks_explorer_selection(2, 4)
      assert.is_nil(err)
      assert.are.same({
        "/path/to/file2.lua",
        "/path/to/file3.lua",
        "/path/to/file4.lua",
      }, files)

      package.loaded["snacks"] = nil
    end)

    it("should handle visual mode with missing items and empty paths", function()
      -- Mock snacks module with some problematic items
      local mock_list = {
        row2idx = function(self, row)
          -- Some rows don't have corresponding indices
          if row == 3 then
            return nil
          end
          return row
        end,
        get = function(self, idx)
          local items = {
            [1] = { file = "" }, -- Empty path
            [2] = { file = "/valid/file.lua" },
            [4] = { path = "/path/based/file.lua" }, -- Using path field
            [5] = nil, -- nil item
          }
          return items[idx]
        end,
      }

      local mock_explorer = {
        list = mock_list,
        selected = function(self, opts)
          return {}
        end,
        current = function(self, opts)
          return { file = "/current.lua" }
        end,
      }

      local mock_snacks = {
        picker = {
          get = function(opts)
            if opts.source == "explorer" then
              return { mock_explorer }
            end
            return {}
          end,
        },
      }

      package.loaded["snacks"] = mock_snacks

      -- Test visual selection from lines 1 to 5
      local files, err = integrations._get_snacks_explorer_selection(1, 5)
      assert.is_nil(err)
      -- Should only get the valid files
      assert.are.same({
        "/valid/file.lua",
        "/path/based/file.lua",
      }, files)

      package.loaded["snacks"] = nil
    end)

    it("should add trailing slashes to directories", function()
      -- Mock vim.fn.isdirectory to return true for directory paths
      local original_isdirectory = vim.fn.isdirectory
      vim.fn.isdirectory = function(path)
        return path:match("/directory") and 1 or 0
      end

      -- Mock snacks module with directory items
      local mock_explorer = {
        selected = function(self, opts)
          return {
            { file = "/path/to/file.lua" }, -- file
            { file = "/path/to/directory" }, -- directory (no trailing slash)
            { file = "/path/to/another_directory/" }, -- directory (already has slash)
          }
        end,
        current = function(self, opts)
          return { file = "/current/directory" } -- directory
        end,
      }

      local mock_snacks = {
        picker = {
          get = function(opts)
            if opts.source == "explorer" then
              return { mock_explorer }
            end
            return {}
          end,
        },
      }

      package.loaded["snacks"] = mock_snacks

      local files, err = integrations._get_snacks_explorer_selection()
      assert.is_nil(err)
      assert.are.same({
        "/path/to/file.lua", -- file unchanged
        "/path/to/directory/", -- directory with added slash
        "/path/to/another_directory/", -- directory with existing slash unchanged
      }, files)

      -- Restore original function
      vim.fn.isdirectory = original_isdirectory
      package.loaded["snacks"] = nil
    end)

    it("should protect against root-level files", function()
      -- Mock snacks module with root-level and safe files
      local mock_explorer = {
        selected = function(self, opts)
          return {
            { file = "/etc/passwd" }, -- root-level file (dangerous)
            { file = "/home/user/file.lua" }, -- safe file
            { file = "/usr/bin/vim" }, -- root-level file (dangerous)
            { file = "/path/to/directory/" }, -- safe directory
          }
        end,
        current = function(self, opts)
          return { file = "/etc/hosts" } -- root-level file
        end,
      }

      local mock_snacks = {
        picker = {
          get = function(opts)
            if opts.source == "explorer" then
              return { mock_explorer }
            end
            return {}
          end,
        },
      }

      package.loaded["snacks"] = mock_snacks

      -- Test selected items - should filter out root-level files
      local files, err = integrations._get_snacks_explorer_selection()
      assert.is_nil(err)
      assert.are.same({
        "/home/user/file.lua",
        "/path/to/directory/",
      }, files)

      package.loaded["snacks"] = nil
    end)

    it("should return error for root-level current file", function()
      -- Mock snacks module with root-level current file and no selection
      local mock_explorer = {
        selected = function(self, opts)
          return {} -- No selection
        end,
        current = function(self, opts)
          return { file = "/etc/passwd" } -- root-level file
        end,
      }

      local mock_snacks = {
        picker = {
          get = function(opts)
            if opts.source == "explorer" then
              return { mock_explorer }
            end
            return {}
          end,
        },
      }

      package.loaded["snacks"] = mock_snacks

      local files, err = integrations._get_snacks_explorer_selection()
      assert.are.same({}, files)
      assert.equals("Cannot add root-level file. Please select a file in a subdirectory.", err)

      package.loaded["snacks"] = nil
    end)
  end)

  describe("get_selected_files_from_tree", function()
    it("should detect snacks_picker_list filetype", function()
      vim.bo.filetype = "snacks_picker_list"

      -- Mock snacks module
      local mock_explorer = {
        selected = function(self, opts)
          return {}
        end,
        current = function(self, opts)
          return { file = "/test/file.lua" }
        end,
      }

      local mock_snacks = {
        picker = {
          get = function(opts)
            if opts.source == "explorer" then
              return { mock_explorer }
            end
            return {}
          end,
        },
      }

      package.loaded["snacks"] = mock_snacks

      local files, err = integrations.get_selected_files_from_tree()
      assert.is_nil(err)
      assert.are.same({ "/test/file.lua" }, files)

      package.loaded["snacks"] = nil
    end)
  end)
end)
