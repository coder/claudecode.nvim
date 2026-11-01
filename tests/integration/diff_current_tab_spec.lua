-- Real-Neovim checks of the tab an openDiff opens in when the user has several tabs. Neovim's own window list decides
-- the order, so under busted's mock vim this is pending; scripts/run_integration_tests_individually.sh runs it in
-- Neovim.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff with several tabs", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openDiff with several tabs", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local tab_name = "✻ [Claude Code] proposed.txt ⧉"
  local dir

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    for _, name in ipairs({ "proposed.txt", "other.txt" }) do
      vim.fn.writefile({ "alpha" }, dir .. "/" .. name)
    end
    tools.register_all()
    _G.claude_deferred_responses = {}
    diff.setup(vim.deepcopy(require("claudecode.config").defaults))
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  local function open_diff()
    local path = dir .. "/proposed.txt"
    local call = tools.handle_invoke({ id = "current_tab_spec" }, {
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
    tools.handle_invoke({ id = "current_tab_spec" }, { name = "close_tab", arguments = { tab_name = tab_name } })
  end

  local function buffers_shown(tab)
    return vim.tbl_map(function(win)
      return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)), ":t")
    end, vim.api.nvim_tabpage_list_wins(tab))
  end

  it("opens in the current tab, not in the empty window of an earlier tab", function()
    local first_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/other.txt"))
    local user_tab = vim.api.nvim_get_current_tabpage()

    local diff_data = open_diff()

    assert.equal(user_tab, vim.api.nvim_get_current_tabpage(), "the user stays in their tab")
    assert.equal(user_tab, vim.api.nvim_win_get_tabpage(diff_data.new_window))
    assert.are.same({ "" }, buffers_shown(first_tab), "the earlier tab is untouched")
    close_tab()
    assert.are.same({ "" }, buffers_shown(first_tab), "the earlier tab still shows its empty window")
    assert.are.same({ "other.txt" }, buffers_shown(user_tab))
  end)

  it("uses the current tab's window that shows the file before one in another tab", function()
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/proposed.txt"))
    vim.cmd("tab split")
    local user_tab = vim.api.nvim_get_current_tabpage()

    local diff_data = open_diff()

    assert.equal(user_tab, vim.api.nvim_get_current_tabpage(), "the user stays in their tab")
    assert.equal(user_tab, vim.api.nvim_win_get_tabpage(diff_data.new_window))
  end)

  it("uses the current tab's editor window before a window in another tab that shows the file", function()
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/proposed.txt"))
    vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/other.txt"))
    local user_tab = vim.api.nvim_get_current_tabpage()

    local diff_data = open_diff()

    assert.equal(user_tab, vim.api.nvim_get_current_tabpage(), "the user stays in their tab")
    assert.equal(user_tab, vim.api.nvim_win_get_tabpage(diff_data.new_window))
  end)

  it("opens in another tab when the current tab has no window it can use", function()
    local editor_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
    vim.cmd("tabnew")
    vim.fn.termopen({ "sleep", "60" })

    local diff_data = open_diff()

    assert.equal(editor_tab, vim.api.nvim_win_get_tabpage(diff_data.new_window))
  end)
end)
