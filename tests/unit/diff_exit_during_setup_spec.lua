-- Neovim exits inside a `nested = true` ClaudeCodeDiffOpened handler, while the second openDiff is still in setup.
-- That call is pending in the diff table, but it has no response sender yet, because the server stores one only after
-- the tool handler yielded. The exit never unwinds the stack, so the setup never returns its early answer. The server's
-- `stop` must answer the call, whichever of the two VimLeavePre autocmds (diff cleanup and server stop) runs first.
-- The real exit, with a child Neovim, is tests/integration/diff_exit_reject_spec.lua.
require("tests.busted_setup")
local temp_dir = require("tests.helpers.temp_dir")

describe("Neovim exits inside a ClaudeCodeDiffOpened handler", function()
  local diff, server, tools, tcp
  local dir, saved_stop_server, saved_exec_autocmds, responses, exited
  local client = { id = "client-setup-exit" }

  ---The VimLeavePre autocmd of diff.lua, run as Neovim runs it.
  local function diff_leave_pre()
    local callbacks = {}
    for _, event in ipairs(vim._autocmds["ClaudeCodeMCPDiff"].events) do
      if event.events == "VimLeavePre" then
        callbacks[#callbacks + 1] = event.opts.callback
      end
    end
    assert.equals(1, #callbacks, "expected one VimLeavePre autocmd in diff.lua")
    callbacks[1]()
  end

  ---Stands in for `callback = function() vim.cmd("qa!") end`: both VimLeavePre autocmds run inside the handler, and
  ---nothing runs after them, because the process is gone.
  local function exit_in_opened_handler(tab_name, order)
    vim.api.nvim_exec_autocmds = function(event, opts)
      if event == "User" and opts.pattern == "ClaudeCodeDiffOpened" and opts.data.tab_name == tab_name then
        for _, step in ipairs(order) do
          step()
        end
        exited = true
      end
      return saved_exec_autocmds(event, opts)
    end
  end

  local function open_diff(id, name)
    local path = dir .. "/" .. name
    local file = assert(io.open(path, "w"))
    file:write("old line\n")
    file:close()
    server._handle_request(client, {
      jsonrpc = "2.0",
      id = id,
      method = "tools/call",
      params = {
        name = "openDiff",
        arguments = { old_file_path = path, new_file_path = path, new_file_contents = "new line\n", tab_name = name },
      },
    })
  end

  local function replies_for(id)
    local found = {}
    for _, response in ipairs(responses) do
      if response.id == id then
        found[#found + 1] = response
      end
    end
    return found
  end

  before_each(function()
    for _, name in ipairs({ "claudecode.diff", "claudecode.server.init" }) do
      package.loaded[name] = nil
    end
    diff = require("claudecode.diff")
    server = require("claudecode.server.init")
    tools = require("claudecode.tools.init")
    tcp = require("claudecode.server.tcp")
    diff.setup({ terminal = {}, diff_opts = {} })
    server.register_handlers()
    tools.setup(server)
    saved_stop_server = tcp.stop_server
    tcp.stop_server = function() end
    server.state.server = {} -- a running server, as far as stop can tell
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return nil
      end,
      ensure_visible = function() end,
    }
    saved_exec_autocmds = vim.api.nvim_exec_autocmds
    dir = temp_dir.new()
    exited, responses = false, {}
    -- Once the process is gone, nothing it would send later leaves it.
    server.send_response = function(_, id, result, error_data)
      if not exited then
        responses[#responses + 1] = { id = id, result = result, error = error_data }
      end
    end
  end)

  after_each(function()
    vim.api.nvim_exec_autocmds = saved_exec_autocmds
    tcp.stop_server = saved_stop_server
    diff._cleanup_all_active_diffs("test cleanup")
    package.loaded["claudecode.terminal"] = nil
    temp_dir.remove(dir)
  end)

  local orders = {
    { name = "the diff cleanup first, then the server", steps = { diff_leave_pre, "stop" } },
    { name = "the server first, then the diff cleanup", steps = { "stop", diff_leave_pre } },
  }

  for _, case in ipairs(orders) do
    it("answers both calls once, with " .. case.name, function()
      local steps = {}
      for _, step in ipairs(case.steps) do
        steps[#steps + 1] = step == "stop" and function()
          server.stop()
        end or step
      end
      open_diff(1, "first.txt") -- setup is over: the diff waits, and its sender exists
      exit_in_opened_handler("second.txt", steps)

      open_diff(2, "second.txt") -- the exit happens in this call's setup

      local first, second = replies_for(1), replies_for(2)
      assert.equals(1, #first, "the waiting call gets one answer")
      assert.equals("DIFF_REJECTED", first[1].result.content[1].text)
      assert.equals(1, #second, "the call in setup gets one answer")
      assert.equals(-32603, second[1].error.code)
      assert.equals(2, #responses)
    end)
  end
end)
