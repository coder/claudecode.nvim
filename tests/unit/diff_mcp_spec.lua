--- Tests for MCP-compliant openDiff blocking behavior
require("tests.busted_setup")
local diff = require("claudecode.diff")

describe("MCP-compliant diff operations", function()
  local test_old_file = "/tmp/test_old_file.txt"
  local test_new_file = "/tmp/test_new_file.txt"
  local test_content_old = "line 1\nline 2\noriginal content"
  local test_content_new = "line 1\nline 2\nnew content\nextra line"
  local test_tab_name = "test_diff_tab"

  before_each(function()
    -- Create test files
    local file = io.open(test_old_file, "w")
    file:write(test_content_old)
    file:close()
  end)

  after_each(function()
    -- Clean up test files
    os.remove(test_old_file)
    -- Clean up any active diffs
    diff._cleanup_all_active_diffs("test_cleanup")
  end)

  describe("open_diff_blocking", function()
    it("should error when not in coroutine context", function()
      local success, err = pcall(diff.open_diff_blocking, test_old_file, test_new_file, test_content_new, test_tab_name)
      assert.is_false(success)
      assert.is_table(err)
      assert.equal(-32000, err.code)
      assert_contains(err.data, "openDiff must run in coroutine context")
    end)

    it("should create MCP-compliant response on file save", function()
      local result = nil
      local co = coroutine.create(function()
        result = diff.open_diff_blocking(test_old_file, test_new_file, test_content_new, test_tab_name)
      end)

      -- Start the coroutine
      local success, err = coroutine.resume(co)
      assert.is_true(success, "Coroutine should start successfully: " .. tostring(err))
      assert.equal("suspended", coroutine.status(co), "Coroutine should be suspended waiting for user action")

      -- Simulate file save
      vim.schedule(function()
        diff._resolve_diff_as_saved(test_tab_name, 1) -- Mock buffer ID
      end)

      -- Wait for resolution
      vim.wait(100, function() -- Reduced from 1000ms to 100ms
        return coroutine.status(co) == "dead"
      end)

      assert.is_not_nil(result)
      assert.is_table(result.content)
      assert.equal("FILE_SAVED", result.content[1].text)
      assert.equal("text", result.content[1].type)
      assert.is_string(result.content[2].text)
      assert.equal("text", result.content[2].type)
    end)

    it("should create MCP-compliant response on diff rejection", function()
      local result = nil
      local co = coroutine.create(function()
        result = diff.open_diff_blocking(test_old_file, test_new_file, test_content_new, test_tab_name)
      end)

      -- Start the coroutine
      local success, err = coroutine.resume(co)
      assert.is_true(success, "Coroutine should start successfully: " .. tostring(err))
      assert.equal("suspended", coroutine.status(co), "Coroutine should be suspended waiting for user action")

      -- Simulate diff rejection
      vim.schedule(function()
        diff._resolve_diff_as_rejected(test_tab_name)
      end)

      -- Wait for resolution
      vim.wait(100, function() -- Reduced from 1000ms to 100ms
        return coroutine.status(co) == "dead"
      end)

      assert.is_not_nil(result)
      assert.is_table(result.content)
      assert.equal("DIFF_REJECTED", result.content[1].text)
      assert.equal("text", result.content[1].type)
      assert.equal(test_tab_name, result.content[2].text)
      assert.equal("text", result.content[2].type)
    end)

    it("should handle non-existent old file as new file", function()
      local non_existent_file = "/tmp/non_existent_file.txt"

      -- Set up mock resolution
      _G.claude_deferred_responses = {
        [tostring(coroutine.running())] = function()
          -- Mock resolution
        end,
      }

      local co = coroutine.create(function()
        diff.open_diff_blocking(non_existent_file, test_new_file, test_content_new, test_tab_name)
      end)

      local success = coroutine.resume(co)
      assert.is_true(success, "Should handle new file scenario successfully")

      -- The coroutine should yield (waiting for user action)
      assert.equal("suspended", coroutine.status(co))

      -- Verify diff state was created for new file
      local active_diffs = diff._get_active_diffs()
      assert.is_table(active_diffs[test_tab_name])
      assert.is_true(active_diffs[test_tab_name].is_new_file)
    end)

    it("should replace existing diff with same tab_name", function()
      -- First diff
      local co1 = coroutine.create(function()
        diff.open_diff_blocking(test_old_file, test_new_file, test_content_new, test_tab_name)
      end)
      local success1, err1 = coroutine.resume(co1)
      assert.is_true(success1, "First diff should start successfully: " .. tostring(err1))
      assert.equal("suspended", coroutine.status(co1), "First coroutine should be suspended")

      -- Second diff with same tab_name should replace the first
      local co2 = coroutine.create(function()
        diff.open_diff_blocking(test_old_file, test_new_file, test_content_new, test_tab_name)
      end)
      local success2, err2 = coroutine.resume(co2)
      assert.is_true(success2, "Second diff should start successfully: " .. tostring(err2))
      assert.equal("suspended", coroutine.status(co2), "Second coroutine should be suspended")

      -- Clean up both coroutines
      vim.schedule(function()
        diff._resolve_diff_as_rejected(test_tab_name)
      end)

      vim.wait(100, function() -- Reduced from 1000ms to 100ms
        return coroutine.status(co2) == "dead"
      end)
    end)
  end)

  describe("Resource cleanup", function()
    it("should clean up buffers on completion", function()
      local initial_buffers = vim.api.nvim_list_bufs()

      local co = coroutine.create(function()
        diff.open_diff_blocking(test_old_file, test_new_file, test_content_new, test_tab_name)
      end)
      coroutine.resume(co)

      -- Simulate completion
      vim.schedule(function()
        diff._resolve_diff_as_saved(test_tab_name, 1)
      end)

      vim.wait(1000, function()
        return coroutine.status(co) == "dead"
      end)

      -- Check that no extra buffers remain
      local final_buffers = vim.api.nvim_list_bufs()
      -- Allow for some variance due to test environment
      assert.is_true(#final_buffers <= #initial_buffers + 2, "Should not leak buffers")
    end)

    it("should clean up autocmds on completion", function()
      local initial_autocmd_count = #vim.api.nvim_get_autocmds({ group = "ClaudeCodeMCPDiff" })

      local co = coroutine.create(function()
        diff.open_diff_blocking(test_old_file, test_new_file, test_content_new, test_tab_name)
      end)
      coroutine.resume(co)

      -- Verify autocmds were created
      local mid_autocmd_count = #vim.api.nvim_get_autocmds({ group = "ClaudeCodeMCPDiff" })
      assert.is_true(mid_autocmd_count > initial_autocmd_count, "Autocmds should be created")

      -- Simulate completion
      vim.schedule(function()
        diff._resolve_diff_as_rejected(test_tab_name)
      end)

      vim.wait(1000, function()
        return coroutine.status(co) == "dead"
      end)

      -- Check that autocmds were cleaned up
      local final_autocmd_count = #vim.api.nvim_get_autocmds({ group = "ClaudeCodeMCPDiff" })
      assert.equal(initial_autocmd_count, final_autocmd_count, "Autocmds should be cleaned up")
    end)
  end)

  describe("State management", function()
    it("should track active diffs correctly", function()
      local co = coroutine.create(function()
        diff.open_diff_blocking(test_old_file, test_new_file, test_content_new, test_tab_name)
      end)
      coroutine.resume(co)

      -- Verify diff is tracked
      -- Note: This test may need adjustment based on actual buffer creation

      -- Clean up
      vim.schedule(function()
        diff._resolve_diff_as_rejected(test_tab_name)
      end)

      vim.wait(1000, function()
        return coroutine.status(co) == "dead"
      end)
    end)

    it("should handle concurrent diffs with different tab_names", function()
      local tab_name_1 = "test_diff_1"
      local tab_name_2 = "test_diff_2"

      local co1 = coroutine.create(function()
        diff.open_diff_blocking(test_old_file, test_new_file, test_content_new, tab_name_1)
      end)
      local co2 = coroutine.create(function()
        diff.open_diff_blocking(test_old_file, test_new_file, test_content_new, tab_name_2)
      end)

      coroutine.resume(co1)
      coroutine.resume(co2)

      assert.equal("suspended", coroutine.status(co1), "First diff should be suspended")
      assert.equal("suspended", coroutine.status(co2), "Second diff should be suspended")

      -- Resolve both
      vim.schedule(function()
        diff._resolve_diff_as_saved(tab_name_1, 1)
        diff._resolve_diff_as_rejected(tab_name_2)
      end)

      vim.wait(100, function() -- Reduced from 1000ms to 100ms
        return coroutine.status(co1) == "dead" and coroutine.status(co2) == "dead"
      end)
    end)
  end)

  describe("Error handling", function()
    it("should handle buffer creation failures gracefully", function()
      -- Mock vim.api.nvim_create_buf to fail
      local original_create_buf = vim.api.nvim_create_buf
      vim.api.nvim_create_buf = function()
        return 0
      end

      local co = coroutine.create(function()
        diff.open_diff_blocking(test_old_file, test_new_file, test_content_new, test_tab_name)
      end)

      local success, err = coroutine.resume(co)
      assert.is_false(success, "Should fail with buffer creation error")
      assert.is_table(err)
      assert.equal(-32000, err.code)
      assert_contains(err.message, "Diff setup failed")

      -- Restore original function
      vim.api.nvim_create_buf = original_create_buf
    end)
  end)
end)
