require("tests.busted_setup")

describe("close_tab and getDiagnostics log lines", function()
  local lines
  local saved

  local function assert_every_line_names(component)
    assert.is_true(#lines > 0, "no log line reached :messages")
    for _, line in ipairs(lines) do
      local got = line:match("^%[ClaudeCode%] %[([^%]]+)%] %[%u+%] %S")
      assert.are.equal(component, got, "wrong component or empty message in: " .. line)
    end
  end

  before_each(function()
    saved = {
      echo = vim.api.nvim_echo,
      notify = vim.notify,
      lsp = vim.lsp,
      diagnostic = vim.diagnostic,
      uri_to_fname = vim.uri_to_fname,
      logger = package.loaded["claudecode.logger"],
      diff = package.loaded["claudecode.diff"],
    }
    lines = {}
    vim.api.nvim_echo = function(chunks, history)
      if history then
        for _, chunk in ipairs(chunks) do
          table.insert(lines, chunk[1])
        end
      end
    end
    vim.notify = function(msg)
      table.insert(lines, msg)
    end
    package.loaded["claudecode.logger"] = nil
    require("claudecode.logger").setup({ log_level = "debug" })
  end)

  after_each(function()
    vim.api.nvim_echo = saved.echo
    vim.notify = saved.notify
    vim.lsp, vim.diagnostic, vim.uri_to_fname = saved.lsp, saved.diagnostic, saved.uri_to_fname
    package.loaded["claudecode.logger"] = saved.logger
    package.loaded["claudecode.diff"] = saved.diff
    vim._buffers[9] = nil
  end)

  it("names close_tab as the component on every path", function()
    local close_tab = require("claudecode.tools.close_tab").handler
    local diff_tab = "✻ [Claude Code] notes.txt (abc123) ⧉"

    close_tab({})
    close_tab({ tab_name = "no-such-tab" })
    close_tab({ tab_name = diff_tab })
    package.loaded["claudecode.diff"] = {
      close_diff_by_tab_name = function()
        return true
      end,
    }
    close_tab({ tab_name = diff_tab })
    package.loaded["claudecode.diff"] = {}
    close_tab({ tab_name = diff_tab })

    assert_every_line_names("close_tab")
    assert_contains(lines, "[ClaudeCode] [close_tab] [DEBUG] close_tab handler called")
    assert_contains(lines, "[ClaudeCode] [close_tab] [ERROR] Missing required parameter: tab_name")
  end)

  it("names getDiagnostics as the component on every path", function()
    vim.lsp = {}
    vim.diagnostic = {
      get = function()
        return {}
      end,
    }
    vim.uri_to_fname = function(uri)
      return uri:sub(#"file://" + 1)
    end
    vim._mock.add_buffer(9, "/tmp/project/open.lua", "return 1")
    local get_diagnostics = require("claudecode.tools.get_diagnostics").handler

    get_diagnostics({})
    get_diagnostics({ uri = "file:///tmp/project/open.lua" })
    assert.has_error(function()
      get_diagnostics({ uri = "file:///tmp/project/closed.lua" })
    end)

    assert_every_line_names("getDiagnostics")
    assert_contains(lines, "[ClaudeCode] [getDiagnostics] [DEBUG] getDiagnostics handler called")
    assert_contains(lines, "[ClaudeCode] [getDiagnostics] [DEBUG] Getting diagnostics for all open buffers")
  end)
end)
