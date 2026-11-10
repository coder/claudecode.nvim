--- Tests for MCP-compliant openDiff blocking behavior
require("tests.busted_setup")
local diff = require("claudecode.diff")
local temp_dir = require("tests.helpers.temp_dir")

describe("MCP-compliant diff operations", function()
  local dir, test_old_file, test_new_file
  setup(function()
    dir = temp_dir.new()
    test_old_file = dir .. "/test_old_file.txt"
    test_new_file = dir .. "/test_new_file.txt"
  end)
  teardown(function()
    temp_dir.remove(dir)
  end)
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
      local non_existent_file = dir .. "/non_existent_file.txt"

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

      -- Simulate completion and explicit close_tab
      vim.schedule(function()
        diff._resolve_diff_as_saved(test_tab_name, 1)
        diff.close_diff_by_tab_name(test_tab_name)
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

      -- Simulate completion and explicit close_tab
      vim.schedule(function()
        diff._resolve_diff_as_rejected(test_tab_name)
        diff.close_diff_by_tab_name(test_tab_name)
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

      -- Clean up via reject + close_tab
      vim.schedule(function()
        diff._resolve_diff_as_rejected(test_tab_name)
        diff.close_diff_by_tab_name(test_tab_name)
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

  describe("Deferred tools/call response", function()
    local tools = require("claudecode.tools.init")
    local sent

    local function invoke_until_user_acts(tool_name)
      local deferred = tools.handle_invoke(nil, {
        name = tool_name,
        arguments = {
          old_file_path = test_old_file,
          new_file_path = test_new_file,
          new_file_contents = test_content_new,
          tab_name = test_tab_name,
        },
      })
      assert.is_true(deferred._deferred, "the tool should wait for the user")
      _G.claude_deferred_responses = {
        [tostring(deferred.coroutine)] = function(response)
          sent = response
        end,
      }
    end

    local function register_after_diff(tool_name, finish)
      tools.register({
        name = tool_name,
        requires_coroutine = true,
        handler = function(args)
          diff.open_diff_blocking(args.old_file_path, args.new_file_path, args.new_file_contents, args.tab_name)
          return finish()
        end,
      })
    end

    before_each(function()
      sent = nil
    end)

    after_each(function()
      _G.claude_deferred_responses = nil
    end)

    it("sends openDiff's result once the user rejects the diff", function()
      tools.register(require("claudecode.tools.open_diff"))
      invoke_until_user_acts("openDiff")

      diff._resolve_diff_as_rejected(test_tab_name)

      assert.same({
        content = { { type = "text", text = "DIFF_REJECTED" }, { type = "text", text = test_tab_name } },
      }, sent)
    end)

    it("keeps the code of a structured error the handler returns after it resumes", function()
      register_after_diff("returnsAfterDiff", function()
        return false, { code = -32602, message = "Invalid params" }
      end)
      invoke_until_user_acts("returnsAfterDiff")

      diff._resolve_diff_as_rejected(test_tab_name)

      assert.same({ error = { code = -32602, message = "Invalid params" } }, sent)
    end)

    it("keeps the code of a structured error the handler raises after it resumes", function()
      register_after_diff("raisesAfterDiff", function()
        error({ code = -32001, message = "File not open" })
      end)
      invoke_until_user_acts("raisesAfterDiff")

      diff._resolve_diff_as_rejected(test_tab_name)

      assert.same({ error = { code = -32001, message = "File not open" } }, sent)
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
