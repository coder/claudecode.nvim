local helpers = require("tests.helpers.setup")
local integrations = require("claudecode.integrations")

describe("snacks.explorer integration", function()
  before_each(function()
    helpers.setup()
  end)

  after_each(function()
    helpers.cleanup()
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