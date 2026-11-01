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

  local function open_diff(file)
    local path = dir .. "/" .. file
    local call = tools.handle_invoke({ id = "window_sizes_spec" }, {
      name = "openDiff",
      arguments = {
        old_file_path = path,
        new_file_path = path,
        new_file_contents = "alpha accepted\n",
        tab_name = tab_name,
      },
    })
    assert.is_true(call._deferred, vim.inspect(call.error))
    _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
    return diff._get_active_diffs()[tab_name]
  end

  local function close_tab()
    tools.handle_invoke({ id = "window_sizes_spec" }, { name = "close_tab", arguments = { tab_name = tab_name } })
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
end)
