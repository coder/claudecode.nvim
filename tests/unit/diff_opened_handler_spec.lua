--- A ClaudeCodeDiffOpened handler runs before openDiff waits for the user. When it accepts or
--- denies the diff, Claude must still get exactly one answer (issue #325).
require("tests.busted_setup")

describe("openDiff answer when a ClaudeCodeDiffOpened handler resolves the diff", function()
  local diff = require("claudecode.diff")
  local server = require("claudecode.server.init")
  local tools = require("claudecode.tools.init")

  local old_file = "/tmp/claudecode_opened_handler.txt"
  local proposed = "line 1\nline 2 changed\n"
  local tab_name = "✻ [Claude Code] opened-handler ⧉"
  local group = "opened_handler_spec"
  local client = { id = "client-1" }
  local responses
  local original_send_response

  local function on_diff_opened(callback)
    vim.api.nvim_create_autocmd("User", { group = group, pattern = "ClaudeCodeDiffOpened", callback = callback })
  end

  local function call_tool(id, name, arguments)
    server._handle_request(client, {
      jsonrpc = "2.0",
      id = id,
      method = "tools/call",
      params = { name = name, arguments = arguments },
    })
  end

  local function call_open_diff(id)
    call_tool(id, "openDiff", {
      old_file_path = old_file,
      new_file_path = old_file,
      new_file_contents = proposed,
      tab_name = tab_name,
    })
  end

  local function responses_for(id)
    local found = {}
    for _, response in ipairs(responses) do
      if response.id == id then
        found[#found + 1] = response
      end
    end
    return found
  end

  before_each(function()
    local f = io.open(old_file, "w")
    f:write("line 1\nline 2\n")
    f:close()
    server.register_handlers()
    tools.register(require("claudecode.tools.open_diff"))
    tools.register(require("claudecode.tools.close_tab"))
    responses = {}
    original_send_response = server.send_response
    server.send_response = function(_, id, result, error_data)
      responses[#responses + 1] = { id = id, result = result, error = error_data }
    end
  end)

  after_each(function()
    server.send_response = original_send_response
    vim.api.nvim_clear_autocmds({ group = group })
    diff._cleanup_all_active_diffs("test_cleanup")
    _G.claude_deferred_responses = nil
    os.remove(old_file)
  end)

  for _, layout in ipairs({ "vertical", "unified" }) do
    describe(layout .. " layout", function()
      before_each(function()
        diff.setup({ terminal = {}, diff_opts = { layout = layout } })
      end)

      it("answers DIFF_REJECTED once when the handler denies the diff", function()
        on_diff_opened(function(args)
          diff._resolve_diff_as_rejected(args.data.tab_name)
        end)

        call_open_diff(1)
        call_tool(2, "close_tab", { tab_name = tab_name })

        assert.same({
          {
            id = 1,
            result = { content = { { type = "text", text = "DIFF_REJECTED" }, { type = "text", text = tab_name } } },
          },
        }, responses_for(1))
        assert.equal("TAB_CLOSED", responses_for(2)[1].result.content[1].text)
      end)

      it("answers FILE_SAVED once when the handler accepts the diff", function()
        on_diff_opened(function(args)
          diff._resolve_diff_as_saved(args.data.tab_name, vim.api.nvim_win_get_buf(args.data.diff_window))
        end)

        call_open_diff(1)
        call_tool(2, "close_tab", { tab_name = tab_name })

        local answers = responses_for(1)
        assert.equal(1, #answers)
        assert.is_nil(answers[1].error)
        assert.equal("FILE_SAVED", answers[1].result.content[1].text)
      end)

      it("still waits for the user when the handler leaves the diff open", function()
        on_diff_opened(function() end)

        call_open_diff(1)
        assert.same({}, responses_for(1))

        diff._resolve_diff_as_rejected(tab_name)
        assert.equal(1, #responses_for(1))
        assert.equal("DIFF_REJECTED", responses_for(1)[1].result.content[1].text)
      end)
    end)
  end
end)
