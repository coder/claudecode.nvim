-- Real-Neovim check of openDiff with `diff_opts.open_in_new_tab` while the Claude terminal has a window. The diff
-- copies the terminal window's options into the new tab, and the options a Neovim version has decide whether that
-- works, so under busted's mock vim this is pending; scripts/run_integration_tests_individually.sh runs it in Neovim,
-- including CI's oldest supported version.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff in a new tab", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openDiff in a new tab", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local dir, terminal_buf, terminal_win, job

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    tools.register_all()
    _G.claude_deferred_responses = {}
    local config = vim.deepcopy(require("claudecode.config").defaults)
    config.diff_opts.open_in_new_tab = true
    diff.setup(config)

    vim.cmd("botright vsplit")
    terminal_win = vim.api.nvim_get_current_win()
    terminal_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(terminal_win, terminal_buf)
    job = vim.fn.termopen({ "sleep", "60" })
    vim.wo[terminal_win].number = false
    vim.wo[terminal_win].signcolumn = "no"
    vim.cmd("wincmd p")
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return terminal_buf
      end,
      ensure_visible = function() end,
    }
  end)

  after_each(function()
    package.loaded["claudecode.terminal"] = nil
    diff._cleanup_all_active_diffs("test cleanup")
    pcall(vim.fn.jobstop, job)
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  local client = { id = "new_tab_spec_client" }
  local tab_name = "✻ [Claude Code] hello.txt ⧉"

  local function open_diff()
    local path = dir .. "/hello.txt"
    vim.fn.writefile({ "alpha" }, path)
    return tools.handle_invoke(client, {
      name = "openDiff",
      arguments = {
        old_file_path = path,
        new_file_path = path,
        new_file_contents = "alpha accepted\n",
        tab_name = tab_name,
      },
    })
  end

  it("opens the diff in a new tab that shows the terminal with its window options", function()
    vim.wo.number = true

    local call = open_diff()

    assert.is_nil(call.error, vim.inspect(call.error))
    assert.is_true(call._deferred, "openDiff waits for the user")
    assert.equal(2, vim.fn.tabpagenr("$"))
    local terminal_in_tab
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_buf(win) == terminal_buf then
        terminal_in_tab = win
      end
    end
    assert.is_not_nil(terminal_in_tab, "the new tab shows the Claude terminal")
    assert.is_false(vim.wo[terminal_in_tab].number)
    assert.equal("no", vim.wo[terminal_in_tab].signcolumn)
  end)

  it("answers the user's :w, then closes the new tab on Claude's close_tab", function()
    local call = open_diff()
    assert.is_true(call._deferred, vim.inspect(call.error))
    local answers = {}
    _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
      answers[#answers + 1] = response
    end

    vim.api.nvim_buf_call(diff._get_active_diffs()[tab_name].new_buffer, function()
      vim.cmd("write")
    end)
    tools.handle_invoke(client, { name = "close_tab", arguments = { tab_name = tab_name } })

    assert.equal("FILE_SAVED", answers[1].content[1].text)
    assert.is_nil(diff._get_active_diffs()[tab_name])
    assert.equal(1, vim.fn.tabpagenr("$"))
    assert.is_true(vim.api.nvim_win_is_valid(terminal_win), "the user's terminal window stays")
  end)
end)
