-- Real-Neovim checks that close_tab gives the user's windows back the sizes they had before openDiff. Neovim's own
-- layout rules ('equalalways', `wincmd =`) decide those sizes, so under busted's mock vim this is pending;
-- scripts/run_integration_tests_individually.sh runs it in Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff window sizes", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openDiff window sizes", function()
  local diff = require("claudecode.diff")
  local terminal = require("claudecode.terminal")
  local tools = require("claudecode.tools.init")
  local tab_name = "✻ [Claude Code] proposed.txt ⧉"
  local dir

  before_each(function()
    vim.o.columns, vim.o.lines = 160, 40
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    for _, name in ipairs({ "proposed.txt", "a.txt", "b.txt" }) do
      vim.fn.writefile({ "alpha" }, dir .. "/" .. name)
    end
    tools.register_all()
    require("claudecode")._create_commands()
    _G.claude_deferred_responses = {}
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "window_sizes_spec")
    diff._cleanup_all_active_diffs("test cleanup")
    terminal.close()
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  local function use_layout(layout, diff_opts)
    local config = vim.deepcopy(require("claudecode.config").defaults)
    config.diff_opts = vim.tbl_extend("force", config.diff_opts, diff_opts or {}, { layout = layout })
    config.terminal = { provider = "native", split_side = "right", split_width_percentage = 0.30 }
    diff.setup(config)
    terminal.setup(config.terminal, "sh -c 'sleep 600'")
  end

  -- Opens the Claude terminal right of the current window, `width` columns wide, and goes back to that window.
  local function open_terminal(width)
    terminal.open()
    assert(
      vim.wait(1000, function()
        return terminal.get_active_terminal_bufnr() ~= nil
      end),
      "the Claude terminal started"
    )
    vim.api.nvim_win_set_width(vim.fn.bufwinid(terminal.get_active_terminal_bufnr()), width)
    vim.cmd("wincmd p")
  end

  local function call_open_diff(file, name)
    local path = dir .. "/" .. file
    return tools.handle_invoke({ id = "window_sizes_spec" }, {
      name = "openDiff",
      arguments = {
        old_file_path = path,
        new_file_path = path,
        new_file_contents = "alpha accepted\n",
        tab_name = name or tab_name,
      },
    })
  end

  local function open_diff(file, name)
    local call = call_open_diff(file, name)
    assert.is_true(call._deferred, vim.inspect(call.error))
    _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
    return diff._get_active_diffs()[name or tab_name]
  end

  local function close_tab(name)
    tools.handle_invoke(
      { id = "window_sizes_spec" },
      { name = "close_tab", arguments = { tab_name = name or tab_name } }
    )
  end

  -- Makes the diff's setup fail once a buffer whose name ends in `suffix` is shown (or entered, with `event`), as a
  -- user's autocmd that errors would.
  local function fail_when_shown(suffix, event)
    vim.api.nvim_create_autocmd(event or "BufWinEnter", {
      group = vim.api.nvim_create_augroup("window_sizes_spec", { clear = true }),
      callback = function(args)
        if args.file:sub(-#suffix) == suffix then
          error("a user's autocmd failed")
        end
      end,
    })
  end

  local function window_sizes()
    return vim.tbl_map(function(win)
      return { win = win, width = vim.api.nvim_win_get_width(win), height = vim.api.nvim_win_get_height(win) }
    end, vim.api.nvim_tabpage_list_wins(0))
  end

  -- Two editors side by side, the left one narrower than half the screen, as after a user's resize.
  local function two_editors()
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    vim.cmd("rightbelow vsplit " .. vim.fn.fnameescape(dir .. "/b.txt"))
    vim.cmd("wincmd t")
    vim.api.nvim_win_set_width(0, 60)
  end

  it("gives two editors back their sizes after a vertical diff", function()
    use_layout("vertical")
    two_editors()
    local before = window_sizes()

    local diff_data = open_diff("a.txt")
    assert.is_false(diff_data.created_new_tab)
    close_tab()

    assert.are.same(before, window_sizes())
  end)

  it("gives two editors back their sizes after a horizontal diff", function()
    use_layout("horizontal")
    two_editors()
    local before = window_sizes()

    local diff_data = open_diff("a.txt")
    assert.is_false(diff_data.created_new_tab)
    close_tab()

    assert.are.same(before, window_sizes())
  end)

  it("gives the sizes back when close_tab comes while the user is in another tab", function()
    use_layout("vertical")
    -- The other tab exists first, so the tab line takes the same row before and after.
    vim.cmd("tabnew")
    local other_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabprevious")
    two_editors()
    local user_tab = vim.api.nvim_get_current_tabpage()
    local before = window_sizes()

    open_diff("a.txt")
    vim.api.nvim_set_current_tabpage(other_tab)
    close_tab()

    vim.api.nvim_set_current_tabpage(user_tab)
    assert.are.same(before, window_sizes())
  end)

  it("gives the sizes back when the diff's setup fails", function()
    use_layout("vertical")
    two_editors()
    local before = window_sizes()
    local user_win = vim.api.nvim_get_current_win()
    fail_when_shown("(proposed)")

    local call = call_open_diff("a.txt")

    assert.is_truthy(call.error, "the setup failed")
    assert.are.same(before, window_sizes())
    assert.equal(user_win, vim.api.nvim_get_current_win(), "the cursor is back in the user's window")
  end)

  -- The sizes saved before `change` must not come back after it: they no longer fit, so Neovim's sizes stay.
  local function assert_no_restore_after(change)
    local saved = diff._save_window_sizes(vim.api.nvim_get_current_tabpage())
    change()
    local changed = window_sizes()

    diff._restore_window_sizes(saved)

    assert.are.same(changed, window_sizes())
  end

  it("does not give sizes back after the screen size changed", function()
    two_editors()
    assert_no_restore_after(function()
      vim.o.columns = 120
    end)
  end)

  it("does not give sizes back after a tab line appeared", function()
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    vim.cmd("split " .. vim.fn.fnameescape(dir .. "/b.txt"))
    vim.api.nvim_win_set_height(0, 10)
    assert_no_restore_after(function()
      vim.cmd("tabnew")
      vim.cmd("tabprevious")
    end)
  end)

  it("does not give sizes back after the user moved a window", function()
    two_editors()
    assert_no_restore_after(function()
      vim.cmd("wincmd K")
    end)
  end)

  it("keeps the width the user gave the Claude terminal", function()
    use_layout("vertical")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    open_terminal(60)
    local before = window_sizes()

    open_diff("a.txt")
    close_tab()

    assert.are.same(before, window_sizes())
  end)

  it("leaves the width of a Claude terminal in another tab alone", function()
    use_layout("vertical")
    vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/b.txt"))
    local diff_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabprevious")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    open_terminal(60)
    local terminal_tab = vim.api.nvim_get_current_tabpage()
    local before = window_sizes()
    vim.api.nvim_set_current_tabpage(diff_tab)

    open_diff("b.txt")
    close_tab()

    vim.api.nvim_set_current_tabpage(terminal_tab)
    assert.are.same(before, window_sizes())
  end)

  it("puts the cursor back in the window it was in", function()
    use_layout("vertical")
    two_editors()
    local user_win = vim.api.nvim_get_current_win()

    open_diff("a.txt")
    close_tab()

    assert.equal(user_win, vim.api.nvim_get_current_win())
  end)

  it("leaves the cursor in the window the user moved it to during the diff", function()
    use_layout("vertical")
    two_editors()
    local other_win = vim.api.nvim_tabpage_list_wins(0)[2]

    open_diff("a.txt")
    vim.api.nvim_set_current_win(other_win)
    close_tab()

    assert.equal(other_win, vim.api.nvim_get_current_win())
  end)

  it("puts the cursor back in the user's tab when the diff's setup fails in another tab", function()
    use_layout("vertical")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    vim.cmd("tabnew")
    vim.fn.termopen({ "sleep", "60" })
    local user_win = vim.api.nvim_get_current_win()
    fail_when_shown("/a.txt", "BufEnter")

    local call = call_open_diff("a.txt")

    assert.is_truthy(call.error, "the setup failed")
    assert.equal(user_win, vim.api.nvim_get_current_win())
  end)

  it("puts the cursor back in the tab the user was in when the diff opened in another tab", function()
    use_layout("vertical")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    vim.cmd("tabnew")
    vim.fn.termopen({ "sleep", "60" })
    local user_win = vim.api.nvim_get_current_win()

    local diff_data = open_diff("a.txt")
    assert.are_not.equal(vim.api.nvim_win_get_tabpage(user_win), vim.api.nvim_win_get_tabpage(diff_data.new_window))
    close_tab()

    assert.equal(user_win, vim.api.nvim_get_current_win())
  end)

  it("keeps the width the user gave the Claude terminal after a diff in its own tab", function()
    use_layout("vertical", { open_in_new_tab = true })
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    open_terminal(60)
    local before = window_sizes()

    assert.is_true(open_diff("a.txt").created_new_tab)
    close_tab()

    assert.are.same(before, window_sizes())
  end)

  it("leaves the width of a Claude terminal in another tab alone after a diff in its own tab", function()
    use_layout("vertical", { open_in_new_tab = true })
    vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/b.txt"))
    local user_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabprevious")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    open_terminal(60)
    local terminal_tab = vim.api.nvim_get_current_tabpage()
    local before = window_sizes()
    vim.api.nvim_set_current_tabpage(user_tab)

    assert.is_true(open_diff("b.txt").created_new_tab)
    close_tab()

    vim.api.nvim_set_current_tabpage(terminal_tab)
    assert.are.same(before, window_sizes())
  end)

  it("gives a Claude terminal it had to show again the idle width after a diff in its own tab", function()
    use_layout("vertical", { open_in_new_tab = true })
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    open_terminal(60)

    open_diff("a.txt")
    vim.api.nvim_win_close(vim.fn.win_findbuf(terminal.get_active_terminal_bufnr())[1], true)
    close_tab()

    local terminal_win = vim.fn.bufwinid(terminal.get_active_terminal_bufnr())
    assert.are_not.equal(-1, terminal_win, "the Claude terminal is shown again")
    assert.equal(math.floor(vim.o.columns * 0.30), vim.api.nvim_win_get_width(terminal_win))
  end)

  -- Opens a diff next to the user's window and a second one, which gets its own tab because the user's tab now has a
  -- diff, then runs :ClaudeCodeCloseAllDiffs. The two names make pairs() list the diffs in different orders.
  local function assert_close_all_returns_cursor(first_name, second_name)
    use_layout("vertical")
    two_editors()
    local user_win = vim.api.nvim_get_current_win()

    open_diff("a.txt", first_name)
    assert.is_true(open_diff("b.txt", second_name).created_new_tab)
    vim.cmd("ClaudeCodeCloseAllDiffs")

    assert.equal(0, vim.tbl_count(diff._get_active_diffs()), "every diff closed")
    assert.equal(user_win, vim.api.nvim_get_current_win(), "the cursor is back where it was before the first diff")
  end

  it("puts the cursor back where it was before the first diff after :ClaudeCodeCloseAllDiffs", function()
    assert_close_all_returns_cursor("✻ [Claude Code] first.txt ⧉", "✻ [Claude Code] second.txt ⧉")
  end)

  it("puts the cursor back where it was before the first diff after :ClaudeCodeCloseAllDiffs, names swapped", function()
    assert_close_all_returns_cursor("✻ [Claude Code] second.txt ⧉", "✻ [Claude Code] first.txt ⧉")
  end)

  it("puts the cursor back in its window with keep_terminal_focus and no Claude terminal shown", function()
    use_layout("vertical", { keep_terminal_focus = true })
    two_editors()
    local user_win = vim.api.nvim_get_current_win()

    open_diff("a.txt")
    vim.wait(50)
    close_tab()

    assert.equal(user_win, vim.api.nvim_get_current_win())
  end)

  if vim.fn.has("nvim-0.9") ~= 1 then
    pending("the unified layout needs Neovim 0.9")
    return
  end

  it("gives the windows of the user's own diff back their sizes after a unified diff", function()
    use_layout("unified")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/b.txt"))
    vim.cmd("vertical diffsplit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    local before = window_sizes()

    local diff_data = open_diff("proposed.txt")
    assert.is_false(diff_data.created_new_tab, "a unified diff opens in the tab of the user's diff")
    close_tab()

    assert.are.same(before, window_sizes())
  end)

  it("puts the cursor back in the window of the user's own diff after a unified diff", function()
    use_layout("unified")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/b.txt"))
    vim.cmd("vertical diffsplit " .. vim.fn.fnameescape(dir .. "/a.txt"))
    local user_win = vim.api.nvim_get_current_win()

    open_diff("proposed.txt")
    close_tab()

    assert.equal(user_win, vim.api.nvim_get_current_win())
  end)

  it("gives the sizes back after two unified diffs in one tab close, the first one first", function()
    use_layout("unified")
    two_editors()
    local before = window_sizes()

    local user_win = vim.api.nvim_get_current_win()

    open_diff("a.txt")
    assert.is_false(open_diff("b.txt", "✻ [Claude Code] second.txt ⧉").created_new_tab)
    close_tab()
    close_tab("✻ [Claude Code] second.txt ⧉")

    assert.are.same(before, window_sizes())
    assert.equal(user_win, vim.api.nvim_get_current_win(), "the cursor is back where it was before the first diff")
  end)

  it("puts the cursor back in the window the user opened the second of two unified diffs from", function()
    use_layout("unified")
    two_editors()
    local second_win = vim.api.nvim_tabpage_list_wins(0)[2]

    open_diff("a.txt")
    vim.api.nvim_set_current_win(second_win)
    open_diff("b.txt", "✻ [Claude Code] second.txt ⧉")
    close_tab("✻ [Claude Code] second.txt ⧉")

    assert.equal(second_win, vim.api.nvim_get_current_win())
  end)

  it("gives the sizes back when the unified diff's setup fails", function()
    use_layout("unified")
    two_editors()
    local before = window_sizes()
    local user_win = vim.api.nvim_get_current_win()
    fail_when_shown("(unified diff)")

    local call = call_open_diff("a.txt")

    assert.is_truthy(call.error, "the setup failed")
    assert.are.same(before, window_sizes())
    assert.equal(user_win, vim.api.nvim_get_current_win(), "the cursor is back in the user's window")
  end)
end)
