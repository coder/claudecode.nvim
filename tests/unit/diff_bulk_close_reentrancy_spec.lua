--- A bulk close fires ClaudeCodeDiffClosed synchronously for each diff it closes. A user
--- handler that accepts another diff from the same bulk close turns that diff into one that
--- holds the user's accepted edits, so the rest of the loop must keep it (issue #342).
require("tests.busted_setup")
local diff = require("claudecode.diff")

describe("bulk close with a ClaudeCodeDiffClosed handler that accepts another diff", function()
  local file_a = "/tmp/issue342_a.txt"
  local file_b = "/tmp/issue342_b.txt"
  local original_exec_autocmds

  before_each(function()
    for _, path in ipairs({ file_a, file_b }) do
      local f = assert(io.open(path, "w"))
      f:write("line 1\nline 2\n")
      f:close()
    end
    original_exec_autocmds = vim.api.nvim_exec_autocmds
  end)

  after_each(function()
    vim.api.nvim_exec_autocmds = original_exec_autocmds
    diff._cleanup_all_active_diffs("test_cleanup")
    os.remove(file_a)
    os.remove(file_b)
  end)

  local function open_pending(file, tab_name, client_id)
    local handle = { result = nil }
    handle.co = coroutine.create(function()
      handle.result = diff.open_diff_blocking(file, file, "line 1\nline 2\nnew line\n", tab_name, client_id)
    end)
    local ok, err = coroutine.resume(handle.co)
    assert.is_true(ok, "diff coroutine should start: " .. tostring(err))
    assert.equal("suspended", coroutine.status(handle.co), "diff should be pending")
    return handle
  end

  -- Stands in for the user's `User ClaudeCodeDiffClosed` autocmd: on the first close, it
  -- accepts the other open diff the way :ClaudeCodeDiffAccept does. Returns a getter for the
  -- tab name it accepted.
  local function accept_other_diff_on_first_close()
    local accepted
    vim.api.nvim_exec_autocmds = function(event, opts)
      if event ~= "User" or opts.pattern ~= "ClaudeCodeDiffClosed" or accepted then
        return
      end
      for tab_name, diff_data in pairs(diff._get_active_diffs()) do
        if tab_name ~= opts.data.tab_name then
          accepted = tab_name
          diff._resolve_diff_as_saved(tab_name, diff_data.new_buffer)
          return
        end
      end
    end
    return function()
      return accepted
    end
  end

  local bulk_closes = {
    [":ClaudeCodeCloseAllDiffs and server stop (close_pending_diffs)"] = function()
      return diff.close_pending_diffs("user command")
    end,
    ["client disconnect (close_diffs_for_client)"] = function()
      return diff.close_diffs_for_client("clientA", "client disconnected")
    end,
  }

  for name, bulk_close in pairs(bulk_closes) do
    it(name .. " keeps the diff the handler accepted", function()
      local handles = {
        ["tab-A"] = open_pending(file_a, "tab-A", "clientA"),
        ["tab-B"] = open_pending(file_b, "tab-B", "clientA"),
      }
      local accepted = accept_other_diff_on_first_close()

      local closed = bulk_close()

      local kept = accepted()
      assert.is_not_nil(kept, "the handler should have accepted the other diff")
      assert.equal("FILE_SAVED", handles[kept].result.content[1].text)
      assert.equal(1, closed)
      local entry = diff._get_active_diffs()[kept]
      assert.is_table(entry, "the accepted diff must stay open")
      assert.equal("saved", entry.status)
    end)
  end
end)
