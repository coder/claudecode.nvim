--- A bulk close fires ClaudeCodeDiffClosed synchronously for each diff it closes. A user
--- handler that accepts another diff from the same bulk close turns that diff into one that
--- holds the user's accepted edits, so the rest of the loop must keep it (issue #342). A
--- handler that rejects another diff leaves nothing to keep, so the loop closes it too (#363).
require("tests.busted_setup")
local diff = require("claudecode.diff")
local temp_dir = require("tests.helpers.temp_dir")

describe("bulk close with a ClaudeCodeDiffClosed handler that resolves another diff", function()
  local dir, file_a, file_b
  setup(function()
    dir = temp_dir.new()
    file_a = dir .. "/issue342_a.txt"
    file_b = dir .. "/issue342_b.txt"
  end)
  teardown(function()
    temp_dir.remove(dir)
  end)
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

  -- The same handler, rejecting the other open diff the way :ClaudeCodeDiffDeny does.
  local function reject_other_diff_on_first_close()
    local rejected
    vim.api.nvim_exec_autocmds = function(event, opts)
      if event ~= "User" or opts.pattern ~= "ClaudeCodeDiffClosed" or rejected then
        return
      end
      for tab_name in pairs(diff._get_active_diffs()) do
        if tab_name ~= opts.data.tab_name then
          rejected = tab_name
          diff._resolve_diff_as_rejected(tab_name)
          return
        end
      end
    end
    return function()
      return rejected
    end
  end

  local bulk_closes = {
    {
      ":ClaudeCodeCloseAllDiffs and server stop (close_pending_diffs)",
      function()
        return diff.close_pending_diffs("user command")
      end,
    },
    {
      "client disconnect (close_diffs_for_client)",
      function()
        return diff.close_diffs_for_client("clientA", "client disconnected")
      end,
    },
  }

  it("client disconnect leaves a rejected diff that replaced a listed one for another client", function()
    open_pending(file_a, "tab-A", "clientA")
    open_pending(file_b, "tab-B", "clientA")
    local replaced = false
    -- On the first close, the handler replaces tab-B with a diff for clientB, and that diff is rejected at once.
    vim.api.nvim_exec_autocmds = function(event, opts)
      if event ~= "User" or opts.pattern ~= "ClaudeCodeDiffClosed" or replaced then
        return
      end
      replaced = true
      local other = opts.data.tab_name == "tab-A" and "tab-B" or "tab-A"
      open_pending(other == "tab-A" and file_a or file_b, other, "clientB")
      diff._resolve_diff_as_rejected(other)
    end

    diff.close_diffs_for_client("clientA", "client disconnected")

    assert.is_true(replaced, "the handler should have replaced the other diff")
    local left = {}
    for tab_name, diff_data in pairs(diff._get_active_diffs()) do
      left[#left + 1] = tab_name .. " " .. diff_data.client_id .. " " .. diff_data.status
    end
    assert.equal(1, #left, "clientB's diff is not on clientA's list, so it must stay")
    assert.truthy(left[1]:find(" clientB rejected$"))
  end)

  for _, case in ipairs(bulk_closes) do
    local name, bulk_close = case[1], case[2]
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

    it(name .. " also closes the diff the handler rejected, and answers each call once", function()
      local answers = 0
      -- Every lookup finds a sender, so a second answer to either call would be counted too.
      _G.claude_deferred_responses = setmetatable({}, {
        __index = function()
          return function()
            answers = answers + 1
          end
        end,
      })
      finally(function()
        _G.claude_deferred_responses = nil
      end)
      local handles = {
        ["tab-A"] = open_pending(file_a, "tab-A", "clientA"),
        ["tab-B"] = open_pending(file_b, "tab-B", "clientA"),
      }
      local rejected = reject_other_diff_on_first_close()

      local closed = bulk_close()

      local other = rejected()
      assert.is_not_nil(other, "the handler should have rejected the other diff")
      assert.equal("DIFF_REJECTED", handles[other].result.content[1].text)
      assert.is_nil(diff._get_active_diffs()[other], "the rejected diff must close too")
      assert.equal(2, closed)
      assert.equal(2, answers, "each openDiff call must get exactly one answer")
    end)
  end
end)
