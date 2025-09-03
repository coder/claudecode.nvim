-- Verifies that rejecting a new-file diff with an empty buffer left open does not crash,
-- and a subsequent write (diff setup) works again.
require("tests.busted_setup")

describe("New file diff: reject then reopen", function()
  local diff

  before_each(function()
    -- Fresh vim mock state
    if vim and vim._mock and vim._mock.reset then
      vim._mock.reset()
    end

    -- Minimal logger stub
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      error = function() end,
      info = function() end,
      warn = function() end,
    }

    -- Reload diff module cleanly
    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")

    -- Setup config on diff
    diff.setup({
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        keep_terminal_focus = false,
        on_new_file_reject = "keep_empty", -- default behavior
      },
      terminal = {},
    })

    -- Create an empty unnamed buffer and set it in current window so _create_diff_view_from_window reuses it
    local empty_buf = vim.api.nvim_create_buf(false, true)
    -- Ensure name is empty and 'modified' is false
    vim.api.nvim_buf_set_name(empty_buf, "")
    vim.api.nvim_buf_set_option(empty_buf, "modified", false)

    -- Make current window use this empty buffer
    local current_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(current_win, empty_buf)
  end)

  it("should reuse empty buffer for new-file diff, not delete it on reject, and allow reopening", function()
    local tab_name = "✻ [TestNewFile] new.lua ⧉"
    local params = {
      old_file_path = "/nonexistent/path/to/new.lua", -- ensure new-file scenario
      new_file_path = "/tmp/new.lua",
      new_file_contents = "print('hello')\n",
      tab_name = tab_name,
    }

    -- Track current window buffer (the reused empty buffer)
    local target_win = vim.api.nvim_get_current_win()
    local reused_buf = vim.api.nvim_win_get_buf(target_win)
    assert.is_true(vim.api.nvim_buf_is_valid(reused_buf))

    -- 1) Setup the diff (should reuse the empty buffer)
    local setup_ok, setup_err = pcall(function()
      diff._setup_blocking_diff(params, function() end)
    end)
    assert.is_true(setup_ok, "Diff setup failed unexpectedly: " .. tostring(setup_err))

    -- Verify state registered (ownership may vary based on window conditions)
    local active = diff._get_active_diffs()
    assert.is_table(active[tab_name])
    -- Ensure the original buffer reference exists and is valid
    assert.is_true(vim.api.nvim_buf_is_valid(active[tab_name].original_buffer))

    -- 2) Reject the diff; cleanup should NOT delete the reused empty buffer
    diff._resolve_diff_as_rejected(tab_name)

    -- After reject, the diff state should be removed
    local active_after_reject = diff._get_active_diffs()
    assert.is_nil(active_after_reject[tab_name])

    -- The reused buffer should still be valid (not deleted)
    assert.is_true(vim.api.nvim_buf_is_valid(reused_buf))

    -- 3) Setup the diff again with the same conditions; should succeed
    local setup_ok2, setup_err2 = pcall(function()
      diff._setup_blocking_diff(params, function() end)
    end)
    assert.is_true(setup_ok2, "Second diff setup failed unexpectedly: " .. tostring(setup_err2))

    -- Verify new state exists again
    local active_again = diff._get_active_diffs()
    assert.is_table(active_again[tab_name])

    -- Clean up to avoid affecting other tests
    diff._cleanup_diff_state(tab_name, "test cleanup")
  end)
end)
