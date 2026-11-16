-- Real-Neovim checks that a diff cleanup that runs while Neovim refuses window changes (the command-line window,
-- E11, or text lock, E565) still answers every waiting openDiff call, and closes each diff once windows can change.
-- Mock vim has neither lock, so under busted this is pending; scripts/run_integration_tests_individually.sh runs it
-- in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("diff cleanup while Neovim refuses window changes", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("diff cleanup while Neovim refuses window changes", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local window_lock = require("tests.helpers.window_lock")
  local client = { id = "locked_cleanup_spec_client" }
  local group = vim.api.nvim_create_augroup("ClaudeCodeLockedCleanupSpec", { clear = true })
  local dir, answers, closed

  local function texts(response)
    return response.content[1].text
  end

  -- The sender stands in for the WebSocket reply of that one call.
  local function open_diff(name, layout, diff_opts)
    diff.setup({
      terminal = { provider = "none" },
      diff_opts = vim.tbl_extend("force", { layout = layout }, diff_opts or {}),
    })
    local path = dir .. "/" .. name
    vim.fn.writefile({ "one", "two" }, path)
    local tab = "✻ [Claude Code] " .. name .. " ⧉"
    local call = tools.handle_invoke(client, {
      name = "openDiff",
      arguments = { old_file_path = path, new_file_path = path, new_file_contents = "one\nTWO\n", tab_name = tab },
    })
    assert.is_true(call._deferred, "openDiff waits for the user")
    answers[tab] = {}
    _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
      table.insert(answers[tab], response)
    end
    return tab, diff._get_active_diffs()[tab]
  end

  -- The older diff sits in the first tab and the newer one in a second tab that has no diff window, so the newer
  -- one opens in its tab's own windows (the current-tab layout).
  local function open_two_diffs(layout)
    local older, older_state = open_diff("older.txt", layout)
    vim.cmd("tabnew")
    local newer, newer_state = open_diff("newer.txt", layout)
    return { tab = older, state = older_state }, { tab = newer, state = newer_state }
  end

  local function wait_until_closed(timeout)
    return vim.wait(timeout or 2000, function()
      return next(diff._get_active_diffs()) == nil
    end, 10)
  end

  local function windows_and_buffers_left(entries)
    local left = {}
    for _, entry in ipairs(entries) do
      if vim.api.nvim_win_is_valid(entry.state.new_window) then
        left[#left + 1] = entry.tab .. " window"
      end
      if vim.api.nvim_buf_is_valid(entry.state.new_buffer) then
        left[#left + 1] = entry.tab .. " buffer"
      end
    end
    return left
  end

  before_each(function()
    vim.o.columns, vim.o.lines = 160, 40
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    tools.register_all()
    _G.claude_deferred_responses = {}
    answers, closed = {}, {}
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "ClaudeCodeDiffClosed",
      callback = function(args)
        closed[#closed + 1] = args.data.tab_name
      end,
    })
  end)

  after_each(function()
    vim.api.nvim_clear_autocmds({ group = group })
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  for _, layout in ipairs({ "vertical", "unified" }) do
    describe("in the " .. layout .. " layout", function()
      it("closes both diffs at once when nothing is locked", function()
        local older, newer = open_two_diffs(layout)

        diff.close_diffs_for_client(client.id, "client disconnected")

        assert.same({}, diff._get_active_diffs())
        assert.same({}, windows_and_buffers_left({ older, newer }))
        assert.same({ "DIFF_REJECTED" }, vim.tbl_map(texts, answers[older.tab]))
        assert.same({ "DIFF_REJECTED" }, vim.tbl_map(texts, answers[newer.tab]))
      end)

      for _, lock in ipairs(window_lock.states) do
        describe("when " .. lock.name, function()
          it("answers both waiting calls once and does not raise", function()
            local older, newer = open_two_diffs(layout)

            lock.enter(function()
              diff.close_diffs_for_client(client.id, "client disconnected")
            end)

            assert.same({ "DIFF_REJECTED" }, vim.tbl_map(texts, answers[older.tab]), "the older call is answered")
            assert.same({ "DIFF_REJECTED" }, vim.tbl_map(texts, answers[newer.tab]), "the newer call is answered")
            assert.is_nil(next(_G.claude_deferred_responses), "no call is left waiting for an answer")
          end)

          it("keeps both diffs registered while locked, then closes them with their windows and buffers", function()
            local older, newer = open_two_diffs(layout)
            local during

            lock.enter(function()
              diff.close_diffs_for_client(client.id, "client disconnected")
              during = {
                registered = vim.tbl_keys(diff._get_active_diffs()),
                left = windows_and_buffers_left({ older, newer }),
              }
            end)

            table.sort(during.registered)
            assert.same({ newer.tab, older.tab }, during.registered, "both stay registered while windows cannot close")
            assert.equal(4, #during.left, "their windows and buffers cannot close yet")
            assert.is_true(wait_until_closed(), "the registry empties once windows can change")
            assert.same({}, windows_and_buffers_left({ older, newer }))
            assert.same(1, #answers[older.tab], "closing sends no second answer")
            assert.same(1, #answers[newer.tab], "closing sends no second answer")
            table.sort(closed)
            assert.same({ newer.tab, older.tab }, closed, "each diff fires ClaudeCodeDiffClosed once")
          end)

          it("closes a diff once when two cleanups ask for it", function()
            local older, newer = open_two_diffs(layout)

            lock.enter(function()
              diff.close_diffs_for_client(client.id, "client disconnected")
              diff.close_rejected_diffs("user command")
            end)

            assert.is_true(wait_until_closed())
            vim.wait(250)
            assert.equal(2, #closed, "one ClaudeCodeDiffClosed per diff")
            assert.same({}, windows_and_buffers_left({ older, newer }))
          end)

          it("closes the diff of a close_tab call after the lock", function()
            local older = open_diff("older.txt", layout)
            local reply

            lock.enter(function()
              reply = tools.handle_invoke(client, { name = "close_tab", arguments = { tab_name = older } })
            end)

            assert.is_nil(reply.error, "close_tab answered with an error: " .. vim.inspect(reply.error))
            assert.equal("TAB_CLOSED", reply.result.content[1].text)
            assert.is_true(wait_until_closed())
          end)

          it("leaves a diff that replaced the waiting one alone", function()
            local tab = open_diff("older.txt", layout)

            lock.enter(function()
              diff.close_diff_by_tab_name(tab)
            end)
            local replacement = open_diff("older.txt", layout)
            vim.wait(400)

            assert.equal(replacement, tab)
            local entry = diff._get_active_diffs()[tab]
            assert.is_not_nil(entry, "the replacing diff is still open")
            assert.equal("pending", entry.status)
            assert.is_true(vim.api.nvim_win_is_valid(entry.new_window), "its window is still open")
          end)
        end)
      end
    end)
  end

  describe("with a diff in its own tab", function()
    for _, lock in ipairs(window_lock.states) do
      it("closes the tab after the lock when " .. lock.name, function()
        local tab = open_diff("tabbed.txt", "vertical", { open_in_new_tab = true })
        assert.equal(2, #vim.api.nvim_list_tabpages(), "the diff opened its own tab")
        vim.api.nvim_set_current_tabpage(diff._get_active_diffs()[tab].original_tab_number)

        lock.enter(function()
          diff.close_diffs_for_client(client.id, "client disconnected")
        end)

        assert.same({ "DIFF_REJECTED" }, vim.tbl_map(texts, answers[tab]))
        assert.is_true(wait_until_closed())
        assert.equal(1, #vim.api.nvim_list_tabpages(), "the diff's tab is closed")
      end)
    end
  end)
end)
