--- A diff the user accepted with :w holds the accepted edits only in its proposed buffer
--- until the Claude client that opened it writes the file. Another client must not tear it
--- down: if the owner died before writing, nothing else holds those edits (issue #342).
require("tests.busted_setup")
local diff = require("claudecode.diff")
local tools = require("claudecode.tools.init")

describe("a diff the user accepted for one Claude client", function()
  local file = "/tmp/issue342_owned.txt"
  local tab = "✻ [Claude Code] issue342_owned.txt (a1) ⧉"
  local owner = { id = "clientA" }
  local other = { id = "clientB" }

  before_each(function()
    tools.register_all()
    _G.claude_deferred_responses = {}
    local f = assert(io.open(file, "w"))
    f:write("line 1\nline 2\n")
    f:close()
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test_cleanup")
    _G.claude_deferred_responses = nil
    os.remove(file)
  end)

  -- A tools/call from `client`, through the entry point the server uses.
  local function call_tool(client, name, arguments)
    return tools.handle_invoke(client, { name = name, arguments = arguments })
  end

  local function open_diff_args(contents)
    return { old_file_path = file, new_file_path = file, new_file_contents = contents, tab_name = tab }
  end

  local function open_and_accept()
    local deferred = call_tool(owner, "openDiff", open_diff_args("line 1\nline 2\naccepted line\n"))
    assert.is_true(deferred._deferred, "openDiff should wait for the user")
    local answer
    _G.claude_deferred_responses[tostring(deferred.coroutine)] = function(response)
      answer = response
    end
    diff._resolve_diff_as_saved(tab, diff._get_active_diffs()[tab].new_buffer)
    assert.equal("FILE_SAVED", answer.content[1].text)
    assert.is_truthy(answer.content[2].text:find("accepted line", 1, true))
    return answer.content[2].text
  end

  local function assert_kept()
    local entry = diff._get_active_diffs()[tab]
    assert.is_table(entry, "the accepted diff must stay open")
    assert.equal("saved", entry.status)
    assert.equal("clientA", entry.client_id)
  end

  it("survives closeAllDiffTabs from another client", function()
    open_and_accept()

    local response = call_tool(other, "closeAllDiffTabs", {})

    assert.equal("CLOSED_0_DIFF_TABS", response.result.content[1].text)
    assert_kept()
  end)

  it("survives close_tab from another client", function()
    open_and_accept()

    call_tool(other, "close_tab", { tab_name = tab })

    assert_kept()
  end)

  it("is not replaced by another client's openDiff on the same tab_name", function()
    open_and_accept()

    local response = call_tool(other, "openDiff", open_diff_args("line 1\nfrom another session\n"))

    assert.is_nil(response._deferred, "the call must be answered at once")
    assert.equal(-32000, response.error.code)
    assert_kept()
  end)

  it("is torn down by closeAllDiffTabs from its own client", function()
    open_and_accept()

    local response = call_tool(owner, "closeAllDiffTabs", {})

    assert.equal("CLOSED_1_DIFF_TABS", response.result.content[1].text)
    assert.is_nil(diff._get_active_diffs()[tab])
  end)

  it("is torn down by close_tab from its own client", function()
    open_and_accept()

    call_tool(owner, "close_tab", { tab_name = tab })

    assert.is_nil(diff._get_active_diffs()[tab])
  end)

  describe("after its client exits", function()
    local notes, saved_notify

    before_each(function()
      notes = {}
      saved_notify = vim.notify
      vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
      end
      require("claudecode")._create_commands()
    end)

    after_each(function()
      vim.notify = saved_notify
    end)

    local function owner_exits()
      diff.close_diffs_for_client(owner.id, "client disconnected")
      assert_kept()
    end

    local function user_closes_all_diffs()
      vim._commands.ClaudeCodeCloseAllDiffs.callback({})
    end

    local function read_file()
      local f = assert(io.open(file, "rb"))
      local text = f:read("*a")
      f:close()
      return text
    end

    local function write_file(text)
      local f = assert(io.open(file, "wb"))
      f:write(text)
      f:close()
    end

    it("is written and closed by :ClaudeCodeCloseAllDiffs, freeing its tab_name", function()
      local accepted = open_and_accept()
      owner_exits()

      user_closes_all_diffs()

      assert.equal(accepted, read_file())
      assert.is_nil(diff._get_active_diffs()[tab])
      local response = call_tool(other, "openDiff", open_diff_args("line 1\nfrom another session\n"))
      assert.is_true(response._deferred, "the tab_name must be free for a new diff")
    end)

    it("is closed by :ClaudeCodeCloseAllDiffs when the file already holds the accepted text", function()
      local accepted = open_and_accept()
      write_file(accepted)
      owner_exits()

      user_closes_all_diffs()

      assert.equal(accepted, read_file())
      assert.is_nil(diff._get_active_diffs()[tab])
    end)

    it("stays open, and the file keeps its later edit, when the file changed after the accept", function()
      open_and_accept()
      write_file("line 1\nedited after the accept\n")
      owner_exits()

      user_closes_all_diffs()

      assert.equal("line 1\nedited after the accept\n", read_file())
      assert_kept()
      assert.is_truthy(notes[#notes].msg:find(file, 1, true), "the warning must name the file")
      assert.equal(vim.log.levels.WARN, notes[#notes].level)
    end)

    it("leaves the file as it was when the write fails partway", function()
      open_and_accept()
      owner_exits()
      local real_open = io.open
      finally(function()
        rawset(io, "open", real_open)
      end)
      -- A full disk: opening for writing truncates, and the write itself fails.
      rawset(io, "open", function(path, mode)
        if mode == "wb" then
          local f = assert(real_open(path, mode))
          return {
            write = function()
              return nil, "No space left on device"
            end,
            close = function()
              return f:close()
            end,
          }
        end
        return real_open(path, mode)
      end)

      user_closes_all_diffs()
      rawset(io, "open", real_open)

      assert.equal("line 1\nline 2\n", read_file())
      assert_kept()
    end)

    it("stays open, and the file is not written, while the file's buffer has unsaved changes", function()
      open_and_accept()
      owner_exits()
      local buf = vim.fn.bufnr(file)
      if buf == -1 then
        buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, file)
      end
      vim.api.nvim_set_option_value("modified", true, { buf = buf })

      user_closes_all_diffs()

      assert.equal("line 1\nline 2\n", read_file())
      assert_kept()
      assert.equal(vim.log.levels.WARN, notes[#notes].level)
    end)
  end)
end)
