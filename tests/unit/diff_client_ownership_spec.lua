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
end)
