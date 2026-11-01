-- Real-Neovim checks of the windows a unified diff opens and closes. Window sizes and the preview window come from
-- Neovim's own layout rules, so under busted's mock vim this is pending; scripts/run_integration_tests_individually.sh
-- runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("unified diff window choice", function()
    pending("needs a real Neovim")
  end)
  return
end

if vim.fn.has("nvim-0.9") ~= 1 then
  describe("unified diff window choice", function()
    pending("the unified layout needs Neovim 0.9")
  end)
  return
end

describe("unified diff window choice", function()
  local diff = require("claudecode.diff")
  local terminal = require("claudecode.terminal")
  local tools = require("claudecode.tools.init")
  local tab = "✻ [Claude Code] b.txt ⧉"
  local dir, path

  local function use(diff_opts)
    local terminal_opts = { provider = "native", split_side = "right", split_width_percentage = 0.30 }
    diff.setup({ terminal = terminal_opts, diff_opts = diff_opts })
    terminal.setup(terminal_opts, "sh -c 'sleep 600'")
  end

  local function open_terminal()
    terminal.open()
    assert(
      vim.wait(1000, function()
        return terminal.get_active_terminal_bufnr() ~= nil
      end),
      "the Claude terminal started"
    )
    return vim.fn.bufwinid(terminal.get_active_terminal_bufnr())
  end

  local function open_diff()
    local call = tools.handle_invoke({ id = "window_choice_spec" }, {
      name = "openDiff",
      arguments = { old_file_path = path, new_file_path = path, new_file_contents = "one\nTWO\n", tab_name = tab },
    })
    assert.is_true(call._deferred, "openDiff waits for the user")
    _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
    return diff._get_active_diffs()[tab].new_window
  end

  local function close_tab()
    tools.handle_invoke({ id = "window_choice_spec" }, { name = "close_tab", arguments = { tab_name = tab } })
  end

  before_each(function()
    vim.o.columns, vim.o.lines = 160, 40
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    path = dir .. "/b.txt"
    vim.fn.writefile({ "one", "two" }, path)
    tools.register_all()
    _G.claude_deferred_responses = {}
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test cleanup")
    terminal.close()
    vim.cmd("silent! tabonly")
    vim.cmd("silent! pclose")
    vim.cmd("silent! only")
    vim.cmd("setlocal nopreviewwindow")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  it("closes its new tab after close_tab when the tab has no Claude terminal", function()
    use({ layout = "unified", open_in_new_tab = true })
    open_diff()
    assert.equal(2, #vim.api.nvim_list_tabpages())

    close_tab()

    assert.equal(1, #vim.api.nvim_list_tabpages())
  end)

  it("closes its new tab after close_tab when hide_terminal_in_new_tab keeps the terminal out of it", function()
    use({ layout = "unified", open_in_new_tab = true, hide_terminal_in_new_tab = true })
    open_terminal()
    open_diff()
    assert.equal(2, #vim.api.nvim_list_tabpages())

    close_tab()

    assert.equal(1, #vim.api.nvim_list_tabpages())
  end)

  it("gives the diff a share of the screen when the Claude terminal is the only window", function()
    use({ layout = "unified" })
    local terminal_win = open_terminal()
    vim.cmd("only")
    assert.equal(vim.o.columns, vim.api.nvim_win_get_width(terminal_win))

    local width = vim.api.nvim_win_get_width(open_diff())

    assert.is_true(width >= math.floor(vim.o.columns / 3) - 1, "the diff is " .. width .. " columns wide")
  end)

  it("splits the Claude terminal's window, not the preview window above it", function()
    use({ layout = "unified" })
    local terminal_win = open_terminal()
    vim.cmd("only")
    vim.cmd("pedit " .. vim.fn.fnameescape(path))
    vim.cmd("wincmd P")
    local preview_win = vim.api.nvim_get_current_win()
    local preview_width = vim.api.nvim_win_get_width(preview_win)
    local terminal_height = vim.api.nvim_win_get_height(terminal_win)

    local diff_win = open_diff()

    assert.equal(preview_width, vim.api.nvim_win_get_width(preview_win), "the preview window keeps its columns")
    assert.equal(terminal_height, vim.api.nvim_win_get_height(diff_win), "the diff gets the terminal's rows")
  end)
end)
