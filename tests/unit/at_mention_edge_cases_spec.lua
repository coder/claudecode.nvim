-- luacheck: globals expect
require("tests.busted_setup")

describe("At Mention Edge Cases", function()
  local init_module
  local mock_vim

  local function setup_mocks()
    package.loaded["claudecode.init"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.config"] = nil

    -- Mock logger
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function(component, ...)
        local args = { ... }
        local message = table.concat(args, " ")
        _G.vim.notify(message, _G.vim.log.levels.WARN)
      end,
      error = function(component, ...)
        local args = { ... }
        local message = table.concat(args, " ")
        _G.vim.notify(message, _G.vim.log.levels.ERROR)
      end,
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

    -- Extend the existing vim mock
    mock_vim = _G.vim or {}

    -- Mock file system functions
    mock_vim.fn = mock_vim.fn or {}
    mock_vim.fn.isdirectory = function(path)
      -- Simulate non-existent paths
      if string.match(path, "nonexistent") or string.match(path, "invalid") then
        return 0
      end
      if string.match(path, "/lua$") or string.match(path, "/tests$") or path == "/Users/test/project" then
        return 1
      end
      return 0
    end

    mock_vim.fn.filereadable = function(path)
      -- Simulate non-existent files
      if string.match(path, "nonexistent") or string.match(path, "invalid") then
        return 0
      end
      if string.match(path, "%.lua$") or string.match(path, "%.txt$") then
        return 1
      end
      return 0
    end

    mock_vim.fn.getcwd = function()
      return "/Users/test/project"
    end

    mock_vim.log = mock_vim.log or {}
    mock_vim.log.levels = {
      ERROR = 1,
      WARN = 2,
      INFO = 3,
    }

    mock_vim.notify = function(message, level)
      -- Store notifications for testing
      mock_vim._last_notification = { message = message, level = level }
    end

    _G.vim = mock_vim
  end

  before_each(function()
    setup_mocks()
    init_module = require("claudecode.init")
  end)

  describe("format_path_for_at_mention validation", function()
    it("should reject nil file_path", function()
      local success, error_msg = pcall(function()
        return init_module._format_path_for_at_mention(nil)
      end)
      expect(success).to_be_false()
      expect(error_msg).to_be_string()
      assert_contains(error_msg, "non-empty string")
    end)

    it("should reject empty string file_path", function()
      local success, error_msg = pcall(function()
        return init_module._format_path_for_at_mention("")
      end)
      expect(success).to_be_false()
      expect(error_msg).to_be_string()
      assert_contains(error_msg, "non-empty string")
    end)

    it("should reject non-string file_path", function()
      local success, error_msg = pcall(function()
        return init_module._format_path_for_at_mention(123)
      end)
      expect(success).to_be_false()
      expect(error_msg).to_be_string()
      assert_contains(error_msg, "non-empty string")
    end)

    it("should reject nonexistent file_path in production", function()
      -- Temporarily simulate production environment
      local old_busted = package.loaded["busted"]
      package.loaded["busted"] = nil

      local success, error_msg = pcall(function()
        return init_module._format_path_for_at_mention("/nonexistent/path.lua")
      end)
      expect(success).to_be_false()
      expect(error_msg).to_be_string()
      assert_contains(error_msg, "does not exist")

      -- Restore test environment
      package.loaded["busted"] = old_busted
    end)

    it("should handle valid file path", function()
      local success, result = pcall(function()
        return init_module._format_path_for_at_mention("/Users/test/project/config.lua")
      end)
      expect(success).to_be_true()
      expect(result).to_be("config.lua")
    end)

    it("should handle valid directory path", function()
      local success, result = pcall(function()
        return init_module._format_path_for_at_mention("/Users/test/project/lua")
      end)
      expect(success).to_be_true()
      expect(result).to_be("lua/")
    end)
  end)

  describe("broadcast_at_mention error handling", function()
    it("should handle format_path_for_at_mention errors gracefully", function()
      -- Mock a running server
      init_module.state = { server = {
        broadcast = function()
          return true
        end,
      } }

      -- Temporarily simulate production environment
      local old_busted = package.loaded["busted"]
      package.loaded["busted"] = nil

      local success, error_msg = init_module._broadcast_at_mention("/invalid/nonexistent/path.lua")
      expect(success).to_be_false()
      expect(error_msg).to_be_string()
      assert_contains(error_msg, "does not exist")

      -- Restore test environment
      package.loaded["busted"] = old_busted
    end)

    it("should handle server not running", function()
      init_module.state = { server = nil }

      local success, error_msg = init_module._broadcast_at_mention("/Users/test/project/config.lua")
      expect(success).to_be_false()
      expect(error_msg).to_be_string()
      assert_contains(error_msg, "not running")
    end)

    it("should handle broadcast failures", function()
      -- Mock a server that fails to broadcast
      init_module.state = { server = {
        broadcast = function()
          return false
        end,
      } }

      local success, error_msg = init_module._broadcast_at_mention("/Users/test/project/config.lua")
      expect(success).to_be_false()
      expect(error_msg).to_be_string()
      assert_contains(error_msg, "Failed to broadcast")
    end)
  end)

  describe("add_paths_to_claude error scenarios", function()
    it("should handle empty file list", function()
      init_module.state = { server = {
        broadcast = function()
          return true
        end,
      } }

      local success_count, total_count = init_module._add_paths_to_claude({})
      expect(success_count).to_be(0)
      expect(total_count).to_be(0)
    end)

    it("should handle nil file list", function()
      init_module.state = { server = {
        broadcast = function()
          return true
        end,
      } }

      local success_count, total_count = init_module._add_paths_to_claude(nil)
      expect(success_count).to_be(0)
      expect(total_count).to_be(0)
    end)

    it("should handle mixed success and failure", function()
      init_module.state = {
        server = {
          broadcast = function(event, params)
            -- Fail for files with "fail" in the name
            return not string.match(params.filePath, "fail")
          end,
        },
      }

      local files = {
        "/Users/test/project/success.lua",
        "/invalid/fail/path.lua",
        "/Users/test/project/another_success.lua",
      }

      local success_count, total_count = init_module._add_paths_to_claude(files, { show_summary = false })
      expect(total_count).to_be(3)
      expect(success_count).to_be(2) -- Two should succeed, one should fail
    end)

    it("should provide user notifications for mixed results", function()
      init_module.state = {
        server = {
          broadcast = function(event, params)
            return not string.match(params.filePath, "fail")
          end,
        },
      }

      local files = {
        "/Users/test/project/success.lua",
        "/invalid/fail/path.lua",
      }

      local success_count, total_count = init_module._add_paths_to_claude(files, { show_summary = true })
      expect(total_count).to_be(2)
      expect(success_count).to_be(1)

      -- Check that a notification was generated
      expect(mock_vim._last_notification).to_be_table()
      expect(mock_vim._last_notification.message).to_be_string()
      assert_contains(mock_vim._last_notification.message, "Added 1 file")
      assert_contains(mock_vim._last_notification.message, "1 failed")
      expect(mock_vim._last_notification.level).to_be(mock_vim.log.levels.WARN)
    end)

    it("should handle all failures", function()
      init_module.state = { server = {
        broadcast = function()
          return false
        end,
      } }

      local files = {
        "/Users/test/project/file1.lua",
        "/Users/test/project/file2.lua",
      }

      local success_count, total_count = init_module._add_paths_to_claude(files, { show_summary = true })
      expect(total_count).to_be(2)
      expect(success_count).to_be(0)

      -- Check that a notification was generated with ERROR level
      expect(mock_vim._last_notification).to_be_table()
      expect(mock_vim._last_notification.level).to_be(mock_vim.log.levels.ERROR)
    end)
  end)

  describe("special path edge cases", function()
    it("should handle paths with spaces", function()
      mock_vim.fn.filereadable = function(path)
        return path == "/Users/test/project/file with spaces.lua" and 1 or 0
      end

      local success, result = pcall(function()
        return init_module._format_path_for_at_mention("/Users/test/project/file with spaces.lua")
      end)
      expect(success).to_be_true()
      expect(result).to_be("file with spaces.lua")
    end)

    it("should handle paths with special characters", function()
      mock_vim.fn.filereadable = function(path)
        return path == "/Users/test/project/file-name_test.lua" and 1 or 0
      end

      local success, result = pcall(function()
        return init_module._format_path_for_at_mention("/Users/test/project/file-name_test.lua")
      end)
      expect(success).to_be_true()
      expect(result).to_be("file-name_test.lua")
    end)

    it("should handle very long paths", function()
      local long_path = "/Users/test/project/" .. string.rep("very_long_directory_name/", 10) .. "file.lua"
      mock_vim.fn.filereadable = function(path)
        return path == long_path and 1 or 0
      end

      local success, result = pcall(function()
        return init_module._format_path_for_at_mention(long_path)
      end)
      expect(success).to_be_true()
      expect(result).to_be_string()
      assert_contains(result, "file.lua")
    end)
  end)
end)
