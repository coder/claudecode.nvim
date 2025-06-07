-- luacheck: globals expect
require("tests.busted_setup")

describe("At Mention Functionality", function()
  local init_module
  local integrations
  local mock_vim

  local function setup_mocks()
    package.loaded["claudecode.init"] = nil
    package.loaded["claudecode.integrations"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.config"] = nil

    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
    }

    -- Mock config
    package.loaded["claudecode.config"] = {
      get = function()
        return {
          debounce_ms = 100,
          visual_demotion_delay_ms = 50,
        }
      end,
    }

    -- Extend the existing vim mock instead of replacing it
    mock_vim = _G.vim or {}

    -- Add or override specific functions for this test
    mock_vim.fn = mock_vim.fn or {}
    mock_vim.fn.isdirectory = function(path)
      if string.match(path, "/lua$") or string.match(path, "/tests$") or path == "/Users/test/project" then
        return 1
      end
      return 0
    end
    mock_vim.fn.getcwd = function()
      return "/Users/test/project"
    end
    mock_vim.fn.mode = function()
      return "n"
    end

    mock_vim.api = mock_vim.api or {}
    mock_vim.api.nvim_get_current_win = function()
      return 1002
    end
    mock_vim.api.nvim_get_mode = function()
      return { mode = "n" }
    end
    mock_vim.api.nvim_get_current_buf = function()
      return 1
    end

    mock_vim.bo = { filetype = "neo-tree" }
    mock_vim.schedule = function(fn)
      fn()
    end

    _G.vim = mock_vim
  end

  before_each(function()
    setup_mocks()
  end)

  describe("file at mention from neo-tree", function()
    before_each(function()
      integrations = require("claudecode.integrations")
      init_module = require("claudecode.init")
    end)

    it("should format single file path correctly", function()
      local mock_state = {
        tree = {
          get_node = function()
            return {
              type = "file",
              path = "/Users/test/project/lua/init.lua",
            }
          end,
        },
      }

      package.loaded["neo-tree.sources.manager"] = {
        get_state = function()
          return mock_state
        end,
      }

      local files, err = integrations._get_neotree_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/lua/init.lua")
    end)

    it("should format directory path with trailing slash", function()
      local mock_state = {
        tree = {
          get_node = function()
            return {
              type = "directory",
              path = "/Users/test/project/lua",
            }
          end,
        },
      }

      package.loaded["neo-tree.sources.manager"] = {
        get_state = function()
          return mock_state
        end,
      }

      local files, err = integrations._get_neotree_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/lua")

      local formatted_path = init_module._format_path_for_at_mention(files[1])
      expect(formatted_path).to_be("lua/")
    end)

    it("should handle relative path conversion", function()
      local file_path = "/Users/test/project/lua/config.lua"
      local formatted_path = init_module._format_path_for_at_mention(file_path)

      expect(formatted_path).to_be("lua/config.lua")
    end)

    it("should handle root project directory", function()
      local dir_path = "/Users/test/project"
      local formatted_path = init_module._format_path_for_at_mention(dir_path)

      expect(formatted_path).to_be("./")
    end)
  end)

  describe("file at mention from nvim-tree", function()
    before_each(function()
      integrations = require("claudecode.integrations")
      init_module = require("claudecode.init")
    end)

    it("should get selected file from nvim-tree", function()
      package.loaded["nvim-tree.api"] = {
        tree = {
          get_node_under_cursor = function()
            return {
              type = "file",
              absolute_path = "/Users/test/project/tests/test_spec.lua",
            }
          end,
        },
        marks = {
          list = function()
            return {}
          end,
        },
      }

      mock_vim.bo.filetype = "NvimTree"

      local files, err = integrations._get_nvim_tree_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/tests/test_spec.lua")
    end)

    it("should get selected directory from nvim-tree", function()
      package.loaded["nvim-tree.api"] = {
        tree = {
          get_node_under_cursor = function()
            return {
              type = "directory",
              absolute_path = "/Users/test/project/tests",
            }
          end,
        },
        marks = {
          list = function()
            return {}
          end,
        },
      }

      mock_vim.bo.filetype = "NvimTree"

      local files, err = integrations._get_nvim_tree_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      expect(files[1]).to_be("/Users/test/project/tests")

      local formatted_path = init_module._format_path_for_at_mention(files[1])
      expect(formatted_path).to_be("tests/")
    end)

    it("should handle multiple marked files in nvim-tree", function()
      package.loaded["nvim-tree.api"] = {
        tree = {
          get_node_under_cursor = function()
            return {
              type = "file",
              absolute_path = "/Users/test/project/init.lua",
            }
          end,
        },
        marks = {
          list = function()
            return {
              { type = "file", absolute_path = "/Users/test/project/config.lua" },
              { type = "file", absolute_path = "/Users/test/project/utils.lua" },
            }
          end,
        },
      }

      mock_vim.bo.filetype = "NvimTree"

      local files, err = integrations._get_nvim_tree_selection()

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(2)
      expect(files[1]).to_be("/Users/test/project/config.lua")
      expect(files[2]).to_be("/Users/test/project/utils.lua")
    end)
  end)

  describe("at mention error handling", function()
    before_each(function()
      integrations = require("claudecode.integrations")
    end)

    it("should handle unsupported buffer types", function()
      mock_vim.bo.filetype = "text"

      local files, err = integrations.get_selected_files_from_tree()

      expect(files).to_be_nil()
      expect(err).to_be_string()
      assert_contains(err, "supported")
    end)

    it("should handle neo-tree errors gracefully", function()
      mock_vim.bo.filetype = "neo-tree"

      package.loaded["neo-tree.sources.manager"] = {
        get_state = function()
          error("Neo-tree not initialized")
        end,
      }

      local success, result_or_error = pcall(function()
        return integrations._get_neotree_selection()
      end)
      expect(success).to_be_false()
      expect(result_or_error).to_be_string()
      assert_contains(result_or_error, "Neo-tree not initialized")
    end)

    it("should handle nvim-tree errors gracefully", function()
      mock_vim.bo.filetype = "NvimTree"

      package.loaded["nvim-tree.api"] = {
        tree = {
          get_node_under_cursor = function()
            error("NvimTree not available")
          end,
        },
        marks = {
          list = function()
            return {}
          end,
        },
      }

      local success, result_or_error = pcall(function()
        return integrations._get_nvim_tree_selection()
      end)
      expect(success).to_be_false()
      expect(result_or_error).to_be_string()
      assert_contains(result_or_error, "NvimTree not available")
    end)
  end)

  describe("integration with main module", function()
    before_each(function()
      integrations = require("claudecode.integrations")
      init_module = require("claudecode.init")
    end)

    it("should send files to Claude via at mention", function()
      local sent_files = {}

      init_module._test_send_at_mention = function(files)
        sent_files = files
      end
      local mock_state = {
        tree = {
          get_node = function()
            return {
              type = "file",
              path = "/Users/test/project/src/main.lua",
            }
          end,
        },
      }

      package.loaded["neo-tree.sources.manager"] = {
        get_state = function()
          return mock_state
        end,
      }

      local files, err = integrations.get_selected_files_from_tree()
      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1)
      if init_module._test_send_at_mention then
        init_module._test_send_at_mention(files)
      end

      expect(#sent_files).to_be(1)
      expect(sent_files[1]).to_be("/Users/test/project/src/main.lua")
    end)

    it("should handle mixed file and directory selection", function()
      local mixed_files = {
        "/Users/test/project/init.lua",
        "/Users/test/project/lua",
        "/Users/test/project/config.lua",
      }

      local formatted_files = {}
      for _, file_path in ipairs(mixed_files) do
        local formatted_path = init_module._format_path_for_at_mention(file_path)
        table.insert(formatted_files, formatted_path)
      end

      expect(#formatted_files).to_be(3)
      expect(formatted_files[1]).to_be("init.lua")
      expect(formatted_files[2]).to_be("lua/")
      expect(formatted_files[3]).to_be("config.lua")
    end)
  end)
end)
