require("tests.busted_setup")

describe("tools/call debug log", function()
  local secret = "API_KEY=sk-live-do-not-log-350"
  local diff = require("claudecode.diff")
  local logger = require("claudecode.logger")
  local tools = require("claudecode.tools.init")
  local old_file = "/tmp/claudecode_tool_call_log_spec.env"
  local server
  local original_echo
  local messages

  local function message_history()
    return table.concat(messages, "\n")
  end

  before_each(function()
    original_echo = vim.api.nvim_echo
    messages = {}
    vim.api.nvim_echo = function(chunks, history)
      if history then
        for _, chunk in ipairs(chunks) do
          table.insert(messages, chunk[1])
        end
      end
    end
    logger.setup({ log_level = "debug" })
    package.loaded["claudecode.server.init"] = nil
    server = require("claudecode.server.init")
    server.register_handlers()
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test_cleanup")
    vim.api.nvim_echo = original_echo
    logger.setup({ log_level = "info" })
  end)

  it("names openDiff's argument keys and sizes but never logs new_file_contents", function()
    tools.register(require("claudecode.tools.open_diff"))
    local contents = secret .. "\n"

    local deferred = server.state.handlers["tools/call"]({ id = "client-1" }, {
      name = "openDiff",
      arguments = {
        old_file_path = old_file,
        new_file_path = old_file,
        new_file_contents = contents,
        tab_name = "tool call log spec",
      },
    })

    assert.is_true(deferred._deferred, "openDiff should wait for the user")
    local log = message_history()
    assert.is_nil(log:find(secret, 1, true), "new_file_contents reached :messages:\n" .. log)
    assert_contains(log, "openDiff")
    assert_contains(log, "new_file_contents=" .. #contents .. " bytes")
  end)

  it("logs a tool's outcome without the text it returns", function()
    tools.register({
      name = "readEnvFile",
      handler = function()
        return { content = { { type = "text", text = secret } } }
      end,
    })

    local result = server.state.handlers["tools/call"]({ id = "client-1" }, { name = "readEnvFile", arguments = {} })

    assert.same({ content = { { type = "text", text = secret } } }, result)
    local log = message_history()
    assert.is_nil(log:find(secret, 1, true), "tool result text reached :messages:\n" .. log)
    assert_contains(log, "Response - tools/call readEnvFile")
  end)
end)
