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

  local function use(diff_opts, terminal_overrides)
    local terminal_opts = vim.tbl_extend(
      "force",
      { provider = "native", split_side = "right", split_width_percentage = 0.30 },
      terminal_overrides or {}
    )
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

  it("sizes a Claude terminal it splits with terminal.diff_split_width_percentage", function()
    use({ layout = "unified" }, { diff_split_width_percentage = 0.20 })
    local terminal_win = open_terminal()
    vim.cmd("only")

    open_diff()

    assert.equal(math.floor(vim.o.columns * 0.20), vim.api.nvim_win_get_width(terminal_win))
  end)

  it("sizes the Claude terminal in its new tab with terminal.diff_split_width_percentage", function()
    use({ layout = "unified", open_in_new_tab = true }, { diff_split_width_percentage = 0.20 })
    open_terminal()
    vim.cmd("wincmd p")

    open_diff()

    local terminal_win = vim.fn.bufwinid(terminal.get_active_terminal_bufnr())
    assert.are_not.equal(-1, terminal_win, "the new tab shows the Claude terminal")
    assert.equal(math.floor(vim.o.columns * 0.20), vim.api.nvim_win_get_width(terminal_win))
  end)

  it("sets no width on the Claude terminal in its new tab when auto_resize_terminal is false", function()
    use({ layout = "unified", open_in_new_tab = true, auto_resize_terminal = false })
    open_terminal()
    vim.cmd("wincmd p")
    local widths_set = {}
    local real_set_width = vim.api.nvim_win_set_width
    vim.api.nvim_win_set_width = function(win, width)
      widths_set[#widths_set + 1] = { buf = vim.api.nvim_win_get_buf(win), width = width }
      return real_set_width(win, width)
    end

    local ok, err = pcall(open_diff)
    vim.api.nvim_win_set_width = real_set_width

    assert.is_true(ok, err)
    assert.are_not.equal(-1, vim.fn.bufwinid(terminal.get_active_terminal_bufnr()), "the new tab shows the terminal")
    for _, call in ipairs(widths_set) do
      assert.are_not.equal(terminal.get_active_terminal_bufnr(), call.buf, "set the terminal to " .. call.width)
    end
  end)

  -- The user is in a tab with only the preview window, and the Claude terminal is in a later tab. The new tab goes
  -- between them, so it comes first in the window list.
  for _, case in ipairs({
    { "with terminal.diff_split_width_percentage", {}, { diff_split_width_percentage = 0.5 } },
    { "with auto_resize_terminal = false", { auto_resize_terminal = false }, {} },
  }) do
    local name, extra_diff_opts, terminal_overrides = case[1], case[2], case[3]
    it("keeps the width of the Claude terminal in another tab after close_tab " .. name, function()
      use(vim.tbl_extend("force", { layout = "unified", open_in_new_tab = true }, extra_diff_opts), terminal_overrides)
      vim.cmd("tabnew")
      local terminal_win = open_terminal()
      local terminal_width = vim.api.nvim_win_get_width(terminal_win)
      vim.cmd("tabprevious")
      vim.cmd("pedit " .. vim.fn.fnameescape(path))
      vim.cmd("wincmd P")
      vim.cmd("only")

      open_diff()
      close_tab()

      assert.equal(terminal_width, vim.api.nvim_win_get_width(terminal_win))
    end)
  end

  it("opens next to an editor window when terminal.split_width_percentage is not a number", function()
    use({ layout = "unified" }, { split_width_percentage = "wide" })
    open_terminal()
    vim.cmd("wincmd p")

    local diff_win = open_diff()

    assert.is_true(vim.api.nvim_win_is_valid(diff_win))
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
