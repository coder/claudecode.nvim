--- A diff the user accepted with :w holds the accepted edits only in its proposed buffer
--- until the Claude client that opened it writes the file. Another client must not tear it
--- down: if the owner died before writing, nothing else holds those edits (issue #342).
require("tests.busted_setup")
local diff = require("claudecode.diff")
local close_tab = require("claudecode.tools.close_tab").handler
local close_all_diff_tabs = require("claudecode.tools.close_all_diff_tabs").handler
local open_diff = require("claudecode.tools.open_diff").handler

describe("a diff the user accepted for one Claude client", function()
  local file = "/tmp/issue342_owned.txt"
  local tab = "✻ [Claude Code] issue342_owned.txt (a1) ⧉"
  local owner = { id = "clientA" }
  local other = { id = "clientB" }

  before_each(function()
    local f = assert(io.open(file, "w"))
    f:write("line 1\nline 2\n")
    f:close()
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test_cleanup")
    os.remove(file)
  end)

  -- Claude's openDiff call as `client`, run the way handle_invoke runs it: in a coroutine.
  local function call_open_diff(client, contents)
    local call = {}
    call.co = coroutine.create(function()
      call.ok, call.result = pcall(open_diff, {
        old_file_path = file,
        new_file_path = file,
        new_file_contents = contents,
        tab_name = tab,
      }, client)
    end)
    assert(coroutine.resume(call.co))
    return call
  end

  local function open_and_accept()
    local call = call_open_diff(owner, "line 1\nline 2\naccepted line\n")
    assert.equal("suspended", coroutine.status(call.co), "openDiff should wait for the user")
    diff._resolve_diff_as_saved(tab, diff._get_active_diffs()[tab].new_buffer)
    assert.equal("FILE_SAVED", call.result.content[1].text)
    return call
  end

  local function assert_kept()
    local entry = diff._get_active_diffs()[tab]
    assert.is_table(entry, "the accepted diff must stay open")
    assert.equal("saved", entry.status)
    assert.equal("clientA", entry.client_id)
  end

  it("survives closeAllDiffTabs from another client", function()
    open_and_accept()

    local result = close_all_diff_tabs({}, other)

    assert.equal("CLOSED_0_DIFF_TABS", result.content[1].text)
    assert_kept()
  end)

  it("survives close_tab from another client", function()
    open_and_accept()

    close_tab({ tab_name = tab }, other)

    assert_kept()
  end)

  it("is not replaced by another client's openDiff on the same tab_name", function()
    open_and_accept()

    local call = call_open_diff(other, "line 1\nfrom another session\n")

    assert.equal("dead", coroutine.status(call.co), "the call must be answered at once")
    assert.is_false(call.ok)
    assert.equal(-32000, call.result.code)
    assert_kept()
  end)

  it("is torn down by closeAllDiffTabs from its own client", function()
    open_and_accept()

    local result = close_all_diff_tabs({}, owner)

    assert.equal("CLOSED_1_DIFF_TABS", result.content[1].text)
    assert.is_nil(diff._get_active_diffs()[tab])
  end)

  it("is torn down by close_tab from its own client", function()
    open_and_accept()

    close_tab({ tab_name = tab }, owner)

    assert.is_nil(diff._get_active_diffs()[tab])
  end)
end)
