-- luacheck: globals expect
require("tests.busted_setup")

describe("NvimTree Visual Selection", function()
  local visual_commands
  local mock_vim

  local function setup_mocks()
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
          return "V" -- Visual line mode
        end,
        getpos = function(mark)
          if mark == "'<" then
            return { 0, 2, 0, 0 } -- Start at line 2
          elseif mark == "'>" then
            return { 0, 4, 0, 0 } -- End at line 4
          elseif mark == "v" then
            return { 0, 2, 0, 0 } -- Anchor at line 2
          end
          return { 0, 0, 0, 0 }
        end,
      },
      api = {
        nvim_get_current_win = function()
          return 1002
        end,
        nvim_get_mode = function()
          return { mode = "V" }
        end,
        nvim_get_current_buf = function()
          return 1
        end,
        nvim_win_get_cursor = function()
          return { 4, 0 } -- Cursor at line 4
        end,
        nvim_buf_get_lines = function(buf, start, end_line, strict)
          -- Return mock buffer lines for the visual selection
          return {
            "  📁 src/",
            "  📄 init.lua",
            "  📄 config.lua",
          }
        end,
        nvim_win_set_cursor = function(win, pos)
          -- Mock cursor setting
        end,
        nvim_replace_termcodes = function(keys, from_part, do_lt, special)
          return keys
        end,
      },
      bo = { filetype = "NvimTree" },
      schedule = function(fn)
        fn()
      end,
    }

    _G.vim = mock_vim
  end

  before_each(function()
    setup_mocks()
  end)

  describe("nvim-tree visual selection handling", function()
    before_each(function()
      visual_commands = require("claudecode.visual_commands")
    end)

    it("should extract files from visual selection in nvim-tree", function()
      -- Create a stateful mock that tracks cursor position
      local cursor_positions = {}
      local expected_nodes = {
        [2] = { type = "directory", absolute_path = "/Users/test/project/src" },
        [3] = { type = "file", absolute_path = "/Users/test/project/init.lua" },
        [4] = { type = "file", absolute_path = "/Users/test/project/config.lua" },
      }

      mock_vim.api.nvim_win_set_cursor = function(win, pos)
        cursor_positions[#cursor_positions + 1] = pos[1]
      end

      local mock_nvim_tree_api = {
        tree = {
          get_node_under_cursor = function()
            local current_line = cursor_positions[#cursor_positions] or 2
            return expected_nodes[current_line]
          end,
        },
      }

      local visual_data = {
        tree_state = mock_nvim_tree_api,
        tree_type = "nvim-tree",
        start_pos = 2,
        end_pos = 4,
      }

      local files, err = visual_commands.get_files_from_visual_selection(visual_data)

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(3)
      expect(files[1]).to_be("/Users/test/project/src")
      expect(files[2]).to_be("/Users/test/project/init.lua")
      expect(files[3]).to_be("/Users/test/project/config.lua")
    end)

    it("should handle empty visual selection in nvim-tree", function()
      local mock_nvim_tree_api = {
        tree = {
          get_node_under_cursor = function()
            return nil -- No node found
          end,
        },
      }

      local visual_data = {
        tree_state = mock_nvim_tree_api,
        tree_type = "nvim-tree",
        start_pos = 2,
        end_pos = 2,
      }

      local files, err = visual_commands.get_files_from_visual_selection(visual_data)

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(0)
    end)

    it("should filter out root-level files in nvim-tree", function()
      local mock_nvim_tree_api = {
        tree = {
          get_node_under_cursor = function()
            return {
              type = "file",
              absolute_path = "/root_file.txt", -- Root-level file should be filtered
            }
          end,
        },
      }

      local visual_data = {
        tree_state = mock_nvim_tree_api,
        tree_type = "nvim-tree",
        start_pos = 1,
        end_pos = 1,
      }

      local files, err = visual_commands.get_files_from_visual_selection(visual_data)

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(0) -- Root-level file should be filtered out
    end)

    it("should remove duplicate files in visual selection", function()
      local call_count = 0
      local mock_nvim_tree_api = {
        tree = {
          get_node_under_cursor = function()
            call_count = call_count + 1
            -- Return the same file path twice to test deduplication
            return {
              type = "file",
              absolute_path = "/Users/test/project/duplicate.lua",
            }
          end,
        },
      }

      local visual_data = {
        tree_state = mock_nvim_tree_api,
        tree_type = "nvim-tree",
        start_pos = 1,
        end_pos = 2, -- Two lines, same file
      }

      local files, err = visual_commands.get_files_from_visual_selection(visual_data)

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(1) -- Should have only one instance
      expect(files[1]).to_be("/Users/test/project/duplicate.lua")
    end)

    it("should handle mixed file and directory selection", function()
      local cursor_positions = {}
      local expected_nodes = {
        [1] = { type = "directory", absolute_path = "/Users/test/project/lib" },
        [2] = { type = "file", absolute_path = "/Users/test/project/main.lua" },
        [3] = { type = "directory", absolute_path = "/Users/test/project/tests" },
      }

      mock_vim.api.nvim_win_set_cursor = function(win, pos)
        cursor_positions[#cursor_positions + 1] = pos[1]
      end

      local mock_nvim_tree_api = {
        tree = {
          get_node_under_cursor = function()
            local current_line = cursor_positions[#cursor_positions] or 1
            return expected_nodes[current_line]
          end,
        },
      }

      local visual_data = {
        tree_state = mock_nvim_tree_api,
        tree_type = "nvim-tree",
        start_pos = 1,
        end_pos = 3,
      }

      local files, err = visual_commands.get_files_from_visual_selection(visual_data)

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(3)
      expect(files[1]).to_be("/Users/test/project/lib")
      expect(files[2]).to_be("/Users/test/project/main.lua")
      expect(files[3]).to_be("/Users/test/project/tests")
    end)
  end)
end)
