--- Claude calls close_tab with the tab_name it gave openDiff. close_tab closes that diff and nothing else: a name
--- without a diff must never close or delete a buffer the user opened.
require("tests.busted_setup")
local diff = require("claudecode.diff")
local tools = require("claudecode.tools.init")

describe("close_tab", function()
  local file = "/tmp/close_tab_spec.txt"
  local user_buffer = 41
  local client = { id = "client-1" }

  before_each(function()
    tools.register_all()
    _G.claude_deferred_responses = {}
    local f = assert(io.open(file, "w"))
    f:write("line 1\n")
    f:close()
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test_cleanup")
    _G.claude_deferred_responses = nil
    vim._buffers[user_buffer] = nil
    os.remove(file)
  end)

  local function close_tab(tab_name)
    local response = tools.handle_invoke(client, { name = "close_tab", arguments = { tab_name = tab_name } })
    return response.result and response.result.content[1].text
  end

  it("closes a diff whose tab name has no markers and answers its openDiff as rejected", function()
    local args = { old_file_path = file, new_file_path = file, new_file_contents = "line 2\n", tab_name = "plain-tab" }
    local deferred = tools.handle_invoke(client, { name = "openDiff", arguments = args })
    assert.is_true(deferred._deferred, "openDiff should wait for the user")
    local answer
    _G.claude_deferred_responses[tostring(deferred.coroutine)] = function(response)
      answer = response
    end

    assert.equal("TAB_CLOSED", close_tab("plain-tab"))

    assert.is_nil(diff._get_active_diffs()["plain-tab"])
    assert.equal("DIFF_REJECTED", answer and answer.content[1].text)
  end)

  it("never deletes a buffer the user opened", function()
    vim._mock.add_buffer(user_buffer, "/tmp/project/README.md", "# readme")

    for _, tab_name in ipairs({
      "README.md",
      "/tmp/project/README.md",
      "✻ [Claude Code] README.md (e18e1e)",
      "✻ [Claude Code] README.md (e18e1e) ⧉",
    }) do
      assert.equal("TAB_CLOSED", close_tab(tab_name))
      assert.is_true(vim.api.nvim_buf_is_valid(user_buffer), "close_tab deleted the user's buffer for " .. tab_name)
    end
  end)
end)
