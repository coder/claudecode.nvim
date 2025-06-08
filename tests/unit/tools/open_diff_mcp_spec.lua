--- Tests for MCP-compliant openDiff tool
require("tests.busted_setup")
local open_diff_tool = require("claudecode.tools.open_diff")

describe("openDiff tool MCP compliance", function()
  local test_old_file = ""
  local test_new_file = ""
  local test_content_old = "line 1\nline 2\noriginal content"
  local test_content_new = "line 1\nline 2\nnew content\nextra line"
  local test_tab_name = "test_diff_tab"

  before_each(function()
    -- Use predictable test file paths for better CI compatibility
    test_old_file = "/test/old_file.txt"
    test_new_file = "/test/new_file.txt"

    -- Mock io.open to return test content without actual file system access
    local original_io_open = io.open
    rawset(io, "open", function(filename, mode)
      if filename == test_old_file and mode == "r" then
        return {
          read = function(self, format)
            if format == "*all" then
              return test_content_old
            end
            return nil
          end,
          close = function() end,
        }
      end
      -- Fall back to original for other files
      return original_io_open(filename, mode)
    end)

    -- Store original for cleanup
    _G._original_io_open = original_io_open
  end)

  after_each(function()
    -- Restore original io.open
    if _G._original_io_open then
      rawset(io, "open", _G._original_io_open)
      _G._original_io_open = nil
    end
    -- Clean up any active diffs
    require("claudecode.diff")._cleanup_all_active_diffs("test_cleanup")
  end)

  describe("tool schema", function()
    it("should have correct tool definition", function()
      assert.equal("openDiff", open_diff_tool.name)
      assert.is_table(open_diff_tool.schema)
      assert.is_function(open_diff_tool.handler)
    end)

    it("should have required parameters in schema", function()
      local required = open_diff_tool.schema.inputSchema.required
      assert.is_table(required)
      assert_contains(required, "old_file_path")
      assert_contains(required, "new_file_path")
      assert_contains(required, "new_file_contents")
      assert_contains(required, "tab_name")
    end)
  end)

  describe("parameter validation", function()
    it("should error on missing required parameters", function()
      local params = {
        old_file_path = test_old_file,
        new_file_path = test_new_file,
        new_file_contents = test_content_new,
        -- missing tab_name
      }

      local co = coroutine.create(function()
        open_diff_tool.handler(params)
      end)

      local success, err = coroutine.resume(co)
      assert.is_false(success)
      assert.is_table(err)
      assert.equal(-32602, err.code)
      assert.matches("Missing required parameter: tab_name", err.data)
    end)

    it("should validate all required parameters", function()
      local required_params = { "old_file_path", "new_file_path", "new_file_contents", "tab_name" }

      for _, param_name in ipairs(required_params) do
        local params = {
          old_file_path = test_old_file,
          new_file_path = test_new_file,
          new_file_contents = test_content_new,
          tab_name = test_tab_name,
        }
        params[param_name] = nil -- Remove the parameter

        local co = coroutine.create(function()
          open_diff_tool.handler(params)
        end)

        local success, err = coroutine.resume(co)
        assert.is_false(success, "Should fail when missing " .. param_name)
        assert.is_table(err)
        assert.equal(-32602, err.code)
        assert.matches("Missing required parameter: " .. param_name, err.data)
      end
    end)
  end)

  describe("coroutine context requirement", function()
    it("should error when not in coroutine context", function()
      local params = {
        old_file_path = test_old_file,
        new_file_path = test_new_file,
        new_file_contents = test_content_new,
        tab_name = test_tab_name,
      }

      local success, err = pcall(open_diff_tool.handler, params)
      assert.is_false(success)
      assert.is_table(err)
      assert.equal(-32000, err.code)
      assert_contains(err.data, "openDiff must run in coroutine context")
    end)
  end)

  describe("MCP-compliant responses", function()
    it("should return MCP format on file save", function()
      local params = {
        old_file_path = test_old_file,
        new_file_path = test_new_file,
        new_file_contents = test_content_new,
        tab_name = test_tab_name,
      }

      local result = nil
      local co = coroutine.create(function()
        result = open_diff_tool.handler(params)
      end)

      -- Start the coroutine
      local success, err = coroutine.resume(co)
      assert.is_true(success, "Tool should start successfully: " .. tostring(err))
      assert.equal("suspended", coroutine.status(co), "Should be suspended waiting for user action")

      -- Simulate file save
      vim.schedule(function()
        require("claudecode.diff")._resolve_diff_as_saved(test_tab_name, 1)
      end)

      -- Wait for resolution
      vim.wait(100, function() -- Reduced from 1000ms to 100ms
        return coroutine.status(co) == "dead"
      end)

      assert.is_not_nil(result)
      assert.is_table(result.content)
      assert.equal(2, #result.content)
      assert.equal("FILE_SAVED", result.content[1].text)
      assert.equal("text", result.content[1].type)
      assert.is_string(result.content[2].text)
      assert.equal("text", result.content[2].type)
    end)

    it("should return MCP format on diff rejection", function()
      local params = {
        old_file_path = test_old_file,
        new_file_path = test_new_file,
        new_file_contents = test_content_new,
        tab_name = test_tab_name,
      }

      local result = nil
      local co = coroutine.create(function()
        result = open_diff_tool.handler(params)
      end)

      -- Start the coroutine
      local success, err = coroutine.resume(co)
      assert.is_true(success, "Tool should start successfully: " .. tostring(err))
      assert.equal("suspended", coroutine.status(co), "Should be suspended waiting for user action")

      -- Simulate diff rejection
      vim.schedule(function()
        require("claudecode.diff")._resolve_diff_as_rejected(test_tab_name)
      end)

      -- Wait for resolution
      vim.wait(100, function() -- Reduced from 1000ms to 100ms
        return coroutine.status(co) == "dead"
      end)

      assert.is_not_nil(result)
      assert.is_table(result.content)
      assert.equal(2, #result.content)
      assert.equal("DIFF_REJECTED", result.content[1].text)
      assert.equal("text", result.content[1].type)
      assert.equal(test_tab_name, result.content[2].text)
      assert.equal("text", result.content[2].type)
    end)
  end)

  describe("error handling", function()
    it("should handle new files successfully", function()
      local params = {
        old_file_path = "/tmp/non_existent_file.txt",
        new_file_path = test_new_file,
        new_file_contents = test_content_new,
        tab_name = test_tab_name,
      }

      -- Set up mock resolution to avoid hanging
      _G.claude_deferred_responses = {
        [tostring(coroutine.running())] = function(result)
          -- Mock resolution
        end,
      }

      local co = coroutine.create(function()
        open_diff_tool.handler(params)
      end)

      local success = coroutine.resume(co)
      assert.is_true(success, "Should handle new file scenario successfully")

      -- The coroutine should yield (waiting for user action)
      assert.equal("suspended", coroutine.status(co))
    end)

    it("should handle diff module loading errors", function()
      -- Mock require to fail
      local original_require = require
      _G.require = function(module)
        if module == "claudecode.diff" then
          error("Mock diff module load failure")
        end
        return original_require(module)
      end

      local params = {
        old_file_path = test_old_file,
        new_file_path = test_new_file,
        new_file_contents = test_content_new,
        tab_name = test_tab_name,
      }

      local co = coroutine.create(function()
        open_diff_tool.handler(params)
      end)

      local success, err = coroutine.resume(co)
      assert.is_false(success)
      assert.is_table(err)
      assert.equal(-32000, err.code)
      assert.matches("Failed to load diff module", err.data)

      -- Restore original require
      _G.require = original_require
    end)

    it("should propagate structured errors from diff module", function()
      -- Mock diff module to throw structured error
      local original_require = require
      _G.require = function(module)
        if module == "claudecode.diff" then
          return {
            open_diff_blocking = function()
              error({
                code = -32001,
                message = "Custom diff error",
                data = "Custom error data",
              })
            end,
          }
        end
        return original_require(module)
      end

      local params = {
        old_file_path = test_old_file,
        new_file_path = test_new_file,
        new_file_contents = test_content_new,
        tab_name = test_tab_name,
      }

      local co = coroutine.create(function()
        open_diff_tool.handler(params)
      end)

      local success, err = coroutine.resume(co)
      assert.is_false(success)
      assert.is_table(err)
      assert.equal(-32001, err.code)
      assert.equal("Custom diff error", err.message)
      assert.equal("Custom error data", err.data)

      -- Restore original require
      _G.require = original_require
    end)
  end)
end)
