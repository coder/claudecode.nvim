require("tests.busted_setup")

local diff = require("claudecode.diff")

describe("Diff UI cleanup behavior", function()
  local test_old_file = "/tmp/test_ui_cleanup_old.txt"
  local tab_name = "test_ui_cleanup_tab"

  before_each(function()
    -- Prepare a dummy file
    local f = io.open(test_old_file, "w")
    f:write("line1\nline2\n")
    f:close()

    -- Reset tabs mock
    vim._tabs = { [1] = true, [2] = true }
    vim._current_tabpage = 2 -- Simulate we're on the newly created tab during cleanup
  end)

  after_each(function()
    os.remove(test_old_file)
    -- Ensure cleanup doesn't leave state behind
    diff._cleanup_all_active_diffs("test_teardown")
  end)

  it("closes the created new tab on accept only after close_tab is invoked", function()
    -- Minimal windows/buffers for cleanup paths
    local new_win = 2001
    local target_win = 2002
    vim._windows[new_win] = { buf = 2 }
    vim._windows[target_win] = { buf = 3 }

    -- Register a pending diff that was opened in a new tab
    diff._register_diff_state(tab_name, {
      old_file_path = test_old_file,
      new_window = new_win,
      target_window = target_win,
      new_buffer = 2,
      original_buffer = 3,
      original_cursor_pos = { 1, 0 },
      original_tab_number = 1,
      created_new_tab = true,
      new_tab_number = 2,
      had_terminal_in_original = false,
      autocmd_ids = {},
      status = "pending",
      resolution_callback = function(_) end,
      is_new_file = false,
    })

    -- Resolve as saved: should NOT close the tab yet
    diff._resolve_diff_as_saved(tab_name, 2)
    assert.is_true(
      vim._last_command == nil or vim._last_command:match("^tabclose") == nil,
      "Did not expect ':tabclose' before close_tab tool call"
    )

    -- Simulate close_tab tool invocation
    local closed = diff.close_diff_by_tab_name(tab_name)
    assert.is_true(closed)
    -- Verify a tabclose command was issued now
    assert.is_true(
      type(vim._last_command) == "string" and vim._last_command:match("^tabclose") ~= nil,
      "Expected a ':tabclose' command to be executed on close_tab"
    )
  end)

  it("keeps Claude terminal visible in original tab on reject when previously visible", function()
    -- Spy on terminal.ensure_visible by preloading a stub module
    local ensure_calls = 0
    package.loaded["claudecode.terminal"] = {
      ensure_visible = function()
        ensure_calls = ensure_calls + 1
        return true
      end,
      get_active_terminal_bufnr = function()
        return nil
      end,
    }

    -- Minimal windows/buffers for cleanup paths
    local new_win = 2101
    local target_win = 2102
    vim._windows[new_win] = { buf = 4 }
    vim._windows[target_win] = { buf = 5 }

    -- Register a pending diff that was opened in a new tab, and track that
    -- the terminal was visible in the original tab when the diff was created
    diff._register_diff_state(tab_name, {
      old_file_path = test_old_file,
      new_window = new_win,
      target_window = target_win,
      new_buffer = 4,
      original_buffer = 5,
      original_cursor_pos = { 1, 0 },
      original_tab_number = 1,
      created_new_tab = true,
      new_tab_number = 2,
      had_terminal_in_original = true,
      autocmd_ids = {},
      status = "pending",
      resolution_callback = function(_) end,
      is_new_file = false,
    })

    -- Mark as rejected and verify no cleanup yet
    diff._resolve_diff_as_rejected(tab_name)
    assert.equals(0, ensure_calls)

    -- Simulate close_tab tool invocation for a pending diff (treated as reject)
    local closed = diff.close_diff_by_tab_name(tab_name)
    assert.is_true(closed)
    -- ensure_visible should have been called exactly once during cleanup
    assert.equals(1, ensure_calls)

    -- Clear the stub to avoid side effects for other tests
    package.loaded["claudecode.terminal"] = nil
  end)
end)
