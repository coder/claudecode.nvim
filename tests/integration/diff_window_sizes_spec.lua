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
    _G.claude_deferred_responses = {}
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "window_sizes_spec")
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  local function use_layout(layout)
    local config = vim.deepcopy(require("claudecode.config").defaults)
    config.diff_opts.layout = layout
    diff.setup(config)
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

  -- Makes the diff's setup fail once its proposed buffer is shown, as a user's autocmd that errors would.
  local function fail_when_shown(suffix)
    vim.api.nvim_create_autocmd("BufWinEnter", {
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
    fail_when_shown("(proposed)")

    local call = call_open_diff("a.txt")

    assert.is_truthy(call.error, "the setup failed")
    assert.are.same(before, window_sizes())
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

  it("gives the sizes back after two unified diffs in one tab close, the first one first", function()
    use_layout("unified")
    two_editors()
    local before = window_sizes()

    open_diff("a.txt")
    assert.is_false(open_diff("b.txt", "✻ [Claude Code] second.txt ⧉").created_new_tab)
    close_tab()
    close_tab("✻ [Claude Code] second.txt ⧉")

    assert.are.same(before, window_sizes())
  end)

  it("gives the sizes back when the unified diff's setup fails", function()
    use_layout("unified")
    two_editors()
    local before = window_sizes()
    fail_when_shown("(unified diff)")

    local call = call_open_diff("a.txt")

    assert.is_truthy(call.error, "the setup failed")
    assert.are.same(before, window_sizes())
  end)
end)
