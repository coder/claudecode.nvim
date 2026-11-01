-- Issue #325: a ClaudeCodeDiffOpened handler that accepts or denies the diff must still answer
-- Claude's openDiff call, exactly once.
require("tests.busted_setup")

describe("a ClaudeCodeDiffOpened handler that resolves the diff (#325)", function()
  local diff = require("claudecode.diff")
  local server = require("claudecode.server.init")
  local tools = require("claudecode.tools.init")

  local old_file = "/tmp/claudecode_opened_handler_325.lua"
  local client = { id = "client-325" }
  local responses
  local orig_send_response, orig_exec_autocmds, orig_get_current_buf

  before_each(function()
    local f = io.open(old_file, "w")
    f:write("local a = 1\n")
    f:close()

    responses = {}
    orig_send_response = server.send_response
    server.send_response = function(_, id, result, error_data)
      responses[#responses + 1] = { id = id, result = result, error = error_data }
    end
    server.register_handlers()
    tools.setup(server)

    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return nil
      end,
      ensure_visible = function() end,
    }
    orig_exec_autocmds = vim.api.nvim_exec_autocmds
    orig_get_current_buf = vim.api.nvim_get_current_buf
  end)

  after_each(function()
    vim.api.nvim_exec_autocmds = orig_exec_autocmds
    vim.api.nvim_get_current_buf = orig_get_current_buf
    server.send_response = orig_send_response
    diff._cleanup_all_active_diffs("test_cleanup")
    package.loaded["claudecode.terminal"] = nil
    os.remove(old_file)
  end)

  -- Stands in for `callback = function() vim.cmd("ClaudeCodeDiffDeny") end`. Neovim runs the
  -- handler with the proposal window current, so the command finds the proposal buffer.
  local function on_diff_opened(command)
    vim.api.nvim_exec_autocmds = function(event, opts)
      if event == "User" and opts.pattern == "ClaudeCodeDiffOpened" then
        vim.api.nvim_get_current_buf = function()
          return vim.api.nvim_win_get_buf(opts.data.diff_window)
        end
        command(opts.data)
        vim.api.nvim_get_current_buf = orig_get_current_buf
      end
      return orig_exec_autocmds(event, opts)
    end
  end

  local function claude_calls(id, tool_name, arguments)
    server._handle_request(client, {
      jsonrpc = "2.0",
      id = id,
      method = "tools/call",
      params = { name = tool_name, arguments = arguments },
    })
  end

  local function answers_for(id)
    local found = {}
    for _, response in ipairs(responses) do
      if response.id == id then
        found[#found + 1] = response
      end
    end
    return found
  end

  local cases = {
    { command = "ClaudeCodeDiffDeny", run = diff.deny_current_diff, answer = "DIFF_REJECTED" },
    { command = "ClaudeCodeDiffAccept", run = diff.accept_current_diff, answer = "FILE_SAVED" },
  }

  for _, layout in ipairs({ "vertical", "unified" }) do
    for _, case in ipairs(cases) do
      it(("answers %s once when the handler runs :%s (%s layout)"):format(case.answer, case.command, layout), function()
        diff.setup({ terminal = {}, diff_opts = { layout = layout } })
        on_diff_opened(case.run)
        local tab_name = "✻ [Claude Code] opened-handler (" .. layout .. ") ⧉"

        claude_calls(1, "openDiff", {
          old_file_path = old_file,
          new_file_path = old_file,
          new_file_contents = "local a = 2\n",
          tab_name = tab_name,
        })

        local answers = answers_for(1)
        assert.are.equal(1, #answers, "openDiff must be answered without any further action")
        assert.is_nil(answers[1].error)
        assert.are.equal(case.answer, answers[1].result.content[1].text)

        claude_calls(2, "close_tab", { tab_name = tab_name })
        assert.are.equal(1, #answers_for(1), "close_tab must not answer openDiff a second time")
        assert.is_nil(diff._get_active_diffs()[tab_name])
      end)
    end
  end

  -- Stands in for a `nested = true` handler that runs `nvim_win_close(args.data.diff_window, true)`. Nested, the
  -- close fires WinClosed, and Neovim runs it before the window leaves the layout. The unified layout has no
  -- WinClosed handler, so closing its window resolves nothing.
  local function close_proposal_window_nested(data)
    for _, entry in ipairs(vim._autocmds["ClaudeCodeMCPDiff"].events) do
      if entry.events == "WinClosed" then
        entry.opts.callback({ match = tostring(data.diff_window) })
      end
    end
    vim.api.nvim_win_close(data.diff_window, true)
  end

  it("answers DIFF_REJECTED once when a nested handler closes the proposal window", function()
    local saved_win_findbuf = vim.fn.win_findbuf
    finally(function()
      vim.fn.win_findbuf = saved_win_findbuf
    end)
    vim.fn.win_findbuf = function(bufnr)
      local wins = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
          wins[#wins + 1] = win
        end
      end
      return wins
    end
    diff.setup({ terminal = {}, diff_opts = { layout = "vertical" } })
    on_diff_opened(close_proposal_window_nested)
    local tab_name = "✻ [Claude Code] opened-handler (nested close) ⧉"

    claude_calls(1, "openDiff", {
      old_file_path = old_file,
      new_file_path = old_file,
      new_file_contents = "local a = 2\n",
      tab_name = tab_name,
    })

    local answers = answers_for(1)
    assert.are.equal(1, #answers, "openDiff must be answered without any further action")
    assert.is_nil(answers[1].error)
    assert.are.equal("DIFF_REJECTED", answers[1].result.content[1].text)

    claude_calls(2, "close_tab", { tab_name = tab_name })
    assert.are.equal(1, #answers_for(1), "close_tab must not answer openDiff a second time")
    assert.is_nil(diff._get_active_diffs()[tab_name])
  end)
end)
