-- luacheck: globals expect
require("tests.busted_setup")

describe("Directory At Mention Functionality", function()
  local integrations
  local visual_commands
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
        isdirectory = function(path)
          if string.match(path, "/lua$") or string.match(path, "/tests$") or string.match(path, "src") then
            return 1
          end
          return 0
        end,
        getcwd = function()
          return "/Users/test/project"
        end,
        mode = function()
          return "n"
        end,
      },
      api = {
        nvim_get_current_win = function()
          return 1002
        end,
        nvim_get_mode = function()
          return { mode = "n" }
        end,
      },
      bo = { filetype = "neo-tree" },
    }

    _G.vim = mock_vim
  end

  before_each(function()
    setup_mocks()
  end)

  describe("directory handling in integrations", function()
    before_each(function()
      integrations = require("claudecode.integrations")
    end)

    it("should return directory paths from neo-tree", function()
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
    end)

    it("should return directory paths from nvim-tree", function()
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
    end)
  end)

  describe("visual commands directory handling", function()
    before_each(function()
      visual_commands = require("claudecode.visual_commands")
    end)

    it("should include directories in visual selections", function()
      local visual_data = {
        tree_state = {
          tree = {
            get_node = function(self, line)
              if line == 1 then
                return {
                  type = "file",
                  path = "/Users/test/project/init.lua",
                  get_depth = function()
                    return 2
                  end,
                }
              elseif line == 2 then
                return {
                  type = "directory",
                  path = "/Users/test/project/lua",
                  get_depth = function()
                    return 2
                  end,
                }
              end
              return nil
            end,
          },
        },
        tree_type = "neo-tree",
        start_pos = 1,
        end_pos = 2,
      }

      local files, err = visual_commands.get_files_from_visual_selection(visual_data)

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(2)
      expect(files[1]).to_be("/Users/test/project/init.lua")
      expect(files[2]).to_be("/Users/test/project/lua")
    end)

    it("should respect depth protection for directories", function()
      local visual_data = {
        tree_state = {
          tree = {
            get_node = function(line)
              if line == 1 then
                return {
                  type = "directory",
                  path = "/Users/test/project",
                  get_depth = function()
                    return 1
                  end,
                }
              end
              return nil
            end,
          },
        },
        tree_type = "neo-tree",
        start_pos = 1,
        end_pos = 1,
      }

      local files, err = visual_commands.get_files_from_visual_selection(visual_data)

      expect(err).to_be_nil()
      expect(files).to_be_table()
      expect(#files).to_be(0) -- Root-level directory should be skipped
    end)
  end)
end)
