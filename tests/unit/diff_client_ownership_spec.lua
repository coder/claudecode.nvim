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

  local function open_and_accept(before_accept, contents)
    local deferred = call_tool(owner, "openDiff", open_diff_args(contents or "line 1\nline 2\naccepted line\n"))
    assert.is_true(deferred._deferred, "openDiff should wait for the user")
    local answer
    _G.claude_deferred_responses[tostring(deferred.coroutine)] = function(response)
      answer = response
    end
    if before_accept then
      before_accept()
    end
    diff._resolve_diff_as_saved(tab, diff._get_active_diffs()[tab].new_buffer)
    assert.equal("FILE_SAVED", answer.content[1].text)
    assert.is_truthy(contents or answer.content[2].text:find("accepted line", 1, true))
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
      local buf = vim.fn.bufnr(file)
      while buf ~= -1 do
        vim.api.nvim_buf_delete(buf, { force = true })
        buf = vim.fn.bufnr(file)
      end
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

    local function file_buffer_lines()
      local buf = vim.fn.bufnr(file)
      assert.are_not.equal(-1, buf, "the file must have a buffer")
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end

    it("is closed by :ClaudeCodeCloseAllDiffs, which puts the accepted text in the file's buffer", function()
      open_and_accept()
      owner_exits()

      user_closes_all_diffs()

      assert.are.same({ "line 1", "line 2", "accepted line" }, file_buffer_lines())
      assert.equal("line 1\nline 2\n", read_file(), "the plugin must never write the file")
      assert.is_nil(diff._get_active_diffs()[tab])
      assert.is_truthy(notes[#notes].msg:find(file, 1, true), "the message must name the file")
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

    it(
      "puts the accepted text in the buffer, and leaves a later edit on disk, when the file changed after the accept",
      function()
        open_and_accept()
        write_file("line 1\nedited after the accept\n")
        owner_exits()

        user_closes_all_diffs()

        assert.equal("line 1\nedited after the accept\n", read_file())
        assert.are.same({ "line 1", "line 2", "accepted line" }, file_buffer_lines())
        assert.is_nil(diff._get_active_diffs()[tab])
      end
    )

    it("gives the buffer the accepted final newline that the file lacked", function()
      write_file("line 1\nline 2")
      open_and_accept(function()
        vim.api.nvim_buf_set_option(diff._get_active_diffs()[tab].new_buffer, "eol", true)
      end)
      owner_exits()

      user_closes_all_diffs()

      assert.are.same({ "line 1", "line 2", "accepted line" }, file_buffer_lines())
      assert.is_true(vim.api.nvim_buf_get_option(vim.fn.bufnr(file), "eol"))
      assert.is_nil(diff._get_active_diffs()[tab])
    end)

    it("closes a diff whose accepted text is empty", function()
      local accepted = open_and_accept(nil, "")
      assert.equal("", accepted)
      owner_exits()

      user_closes_all_diffs()

      assert.are.same({ "" }, file_buffer_lines())
      assert.is_false(vim.api.nvim_buf_get_option(vim.fn.bufnr(file), "eol"))
      assert.is_nil(diff._get_active_diffs()[tab])
    end)

    it("stays open when loading the file changes its buffer", function()
      open_and_accept()
      owner_exits()
      local loaded = vim.fn.bufnr(file)
      if loaded ~= -1 then
        vim.api.nvim_buf_delete(loaded, { force = true })
      end
      local real_bufload = vim.fn.bufload
      finally(function()
        vim.fn.bufload = real_bufload
      end)
      -- A BufReadPost autocmd that edits the buffer while it loads.
      vim.fn.bufload = function(buf)
        real_bufload(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed by a BufReadPost autocmd" })
        vim.api.nvim_set_option_value("modified", true, { buf = buf })
      end

      user_closes_all_diffs()

      assert.are.same({ "changed by a BufReadPost autocmd" }, file_buffer_lines())
      assert_kept()
    end)

    it("stays open on a swap file from another Neovim, and names the next step", function()
      open_and_accept()
      owner_exits()
      local loaded = vim.fn.bufnr(file)
      if loaded ~= -1 then
        vim.api.nvim_buf_delete(loaded, { force = true })
      end
      local real_bufload = vim.fn.bufload
      finally(function()
        vim.fn.bufload = real_bufload
      end)
      vim.fn.bufload = function()
        error("Vim:E325: ATTENTION")
      end

      user_closes_all_diffs()

      assert_kept()
      assert.equal(-1, vim.fn.bufnr(file), "the command leaves no buffer behind")
      local msg = notes[#notes].msg
      assert.is_truthy(msg:find("E325: ATTENTION", 1, true), msg)
      assert.is_truthy(
        msg:find("open it with :e, answer the swap file prompt, then run the command again", 1, true),
        msg
      )
    end)

    it("stays open when it cannot change a buffer that already shows the accepted lines", function()
      open_and_accept()
      owner_exits()
      local buf = vim.fn.bufnr(file)
      if buf == -1 then
        buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, file)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "line 2", "accepted line" })
      vim.api.nvim_set_option_value("modified", false, { buf = buf })
      vim.api.nvim_buf_set_option(buf, "modifiable", false)

      user_closes_all_diffs()

      assert.equal("line 1\nline 2\n", read_file())
      assert_kept()
    end)

    it("hands the text to the file the diff showed, after a :cd while the diff was open", function()
      local real_getcwd = vim.fn.getcwd
      local shown = "/tmp/issue363_open_dir/issue363_relative.txt"
      local elsewhere = "/tmp/issue363_other_dir/issue363_relative.txt"
      local relative_tab = "✻ [Claude Code] issue363_relative.txt ⧉"
      finally(function()
        vim.fn.getcwd = real_getcwd
        for _, path in ipairs({ shown, elsewhere }) do
          if vim.fn.bufnr(path) ~= -1 then
            vim.api.nvim_buf_delete(vim.fn.bufnr(path), { force = true })
          end
        end
      end)
      vim.fn.getcwd = function()
        return "/tmp/issue363_open_dir"
      end
      local deferred = call_tool(owner, "openDiff", {
        old_file_path = "issue363_relative.txt",
        new_file_path = "issue363_relative.txt",
        new_file_contents = "relative accepted\n",
        tab_name = relative_tab,
      })
      assert.is_true(deferred._deferred, "openDiff should wait for the user")
      _G.claude_deferred_responses[tostring(deferred.coroutine)] = function() end
      vim.fn.getcwd = function()
        return "/tmp/issue363_other_dir"
      end
      diff._resolve_diff_as_saved(relative_tab, diff._get_active_diffs()[relative_tab].new_buffer)
      diff.close_diffs_for_client(owner.id, "client disconnected")

      user_closes_all_diffs()

      assert.are_not.equal(-1, vim.fn.bufnr(shown), "the file the diff showed must get the text")
      assert.are.same({ "relative accepted" }, vim.api.nvim_buf_get_lines(vim.fn.bufnr(shown), 0, -1, false))
      assert.equal(-1, vim.fn.bufnr(elsewhere), "a file in the new cwd must not get the text")
      assert.is_nil(diff._get_active_diffs()[relative_tab])
    end)

    it("makes a bufhidden=wipe buffer survive the close of its last window", function()
      open_and_accept()
      owner_exits()
      local buf = vim.fn.bufnr(file)
      if buf == -1 then
        buf = vim.fn.bufadd(file)
        vim.fn.bufload(buf)
      end
      vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

      user_closes_all_diffs()

      assert.are.same({ "line 1", "line 2", "accepted line" }, file_buffer_lines())
      assert.equal("hide", vim.api.nvim_buf_get_option(vim.fn.bufnr(file), "bufhidden"))
    end)

    it("stays open when the file's buffer cannot be written", function()
      open_and_accept()
      owner_exits()
      local buf = vim.fn.bufnr(file)
      if buf == -1 then
        buf = vim.fn.bufadd(file)
        vim.fn.bufload(buf)
      end
      vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
      local lines_before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      user_closes_all_diffs()

      assert.are.same(lines_before, file_buffer_lines())
      assert_kept()
    end)

    it("stays open, and the buffer keeps its edits, while the file's buffer has unsaved changes", function()
      open_and_accept()
      owner_exits()
      local buf = vim.fn.bufnr(file)
      if buf == -1 then
        buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, file)
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "unsaved user edit" })
      vim.api.nvim_set_option_value("modified", true, { buf = buf })

      user_closes_all_diffs()

      assert.are.same({ "line 1", "unsaved user edit" }, file_buffer_lines())
      assert.equal("line 1\nline 2\n", read_file())
      assert_kept()
      assert.is_truthy(notes[#notes].msg:find(file, 1, true), "the warning must name the file")
      assert.equal(vim.log.levels.WARN, notes[#notes].level)
    end)
  end)
end)
