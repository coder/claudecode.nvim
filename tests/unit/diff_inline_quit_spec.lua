require("tests.busted_setup")

-- Mock-vim guard for the unified diff's :q and buffer-switch rejects.
-- The real :q and the real switches run in tests/integration/diff_quit_reject_spec.lua.
describe("Unified diff and :q", function()
  local open_diff_tool = require("claudecode.tools.open_diff")
  local diff = require("claudecode.diff")

  local test_old_file = "/tmp/claudecode_inline_quit_old.txt"
  local test_tab_name = "inline-quit"
  local saved_win_findbuf

  local function callbacks_for(event_name)
    local group = vim._autocmds["ClaudeCodeMCPDiff"]
    assert(group, "ClaudeCodeMCPDiff augroup was not created")
    local callbacks = {}
    for _, ev in ipairs(group.events) do
      if ev.events == event_name then
        callbacks[#callbacks + 1] = ev.opts.callback
      end
    end
    return callbacks
  end

  local function winclosed_callbacks()
    return callbacks_for("WinClosed")
  end

  local function open_diff()
    diff.setup({ terminal = { provider = "none" }, diff_opts = { layout = "unified" } })
    local result
    local co = coroutine.create(function()
      result = open_diff_tool.handler({
        old_file_path = test_old_file,
        new_file_path = test_old_file,
        new_file_contents = "line1\nCHANGED\nline3\n",
        tab_name = test_tab_name,
      })
    end)
    local ok, err = coroutine.resume(co)
    assert.is_true(ok, tostring(err))
    assert.equal("suspended", coroutine.status(co))
    return diff._get_active_diffs()[test_tab_name], function()
      return result
    end
  end

  before_each(function()
    local f = io.open(test_old_file, "w")
    f:write("line1\nline2\nline3\n")
    f:close()
    diff._cleanup_all_active_diffs("test_setup")
    saved_win_findbuf = vim.fn.win_findbuf
  end)

  after_each(function()
    vim.fn.win_findbuf = saved_win_findbuf
    os.remove(test_old_file)
    diff._cleanup_all_active_diffs("test_teardown")
  end)

  it("keeps the proposal buffer on window close, like the split layout", function()
    local state = open_diff()
    -- bufhidden=wipe makes :q on this modified buffer fail with E37, and no window closes.

    assert.equal("hide", vim.api.nvim_buf_get_option(state.new_buffer, "bufhidden"))
  end)

  it("registers the window-close and hidden-buffer rejects and tears them down with the diff", function()
    open_diff()

    assert.equal(1, #winclosed_callbacks())
    assert.equal(1, #callbacks_for("BufHidden"))

    diff._cleanup_diff_state(test_tab_name, "test cleanup")
    assert.equal(0, #winclosed_callbacks(), "cleanup left the WinClosed autocmd behind")
    assert.equal(0, #callbacks_for("BufHidden"), "cleanup left the BufHidden autocmd behind")
  end)

  it("rejects when the window switches to another buffer and the proposal is shown nowhere", function()
    local state, result = open_diff()
    vim.fn.win_findbuf = function()
      return {}
    end

    callbacks_for("BufHidden")[1]({ buf = state.new_buffer })

    assert.equal("rejected", diff._get_active_diffs()[test_tab_name].status)
    assert.equal("DIFF_REJECTED", result().content[1].text)
  end)

  it("rejects once the closing window was the last to show the proposal", function()
    local state, result = open_diff()
    vim.fn.win_findbuf = function()
      return { state.new_window }
    end

    winclosed_callbacks()[1]({ match = tostring(state.new_window) })

    assert.equal("rejected", diff._get_active_diffs()[test_tab_name].status)
    assert.is_table(result())
    assert.equal("DIFF_REJECTED", result().content[1].text)
  end)

  it("keeps waiting while another window shows the proposal", function()
    local state, result = open_diff()
    vim.fn.win_findbuf = function()
      return { state.new_window, state.new_window + 1000 }
    end

    winclosed_callbacks()[1]({ match = tostring(state.new_window) })

    assert.equal("pending", diff._get_active_diffs()[test_tab_name].status)
    assert.is_nil(result())
  end)
end)
