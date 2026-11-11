-- Real-Neovim guards for openDiff with `diff_opts.open_in_new_tab`: when the diff setup fails after `:tabnew` and a
-- handler of the user raises while the plugin cleans up, openDiff still answers "Diff setup failed", closes the tab
-- it opened and goes back to the tab it left. Under busted's mock vim this is pending;
-- scripts/run_integration_tests_individually.sh runs it in Neovim, including CI's oldest supported version.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff when the setup fails in a new tab", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openDiff when the setup fails in a new tab", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local tab_name = "✻ [Claude Code] proposal ⧉"
  local group = "diff_failed_setup_guards_spec"
  local dir, path

  local function shows_the_proposal(buf)
    return vim.api.nvim_buf_get_name(buf):find(tab_name, 1, true) ~= nil
  end

  local function wipe_the_proposal_when_shown()
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = group,
      callback = function(args)
        if shows_the_proposal(args.buf) then
          vim.api.nvim_buf_delete(args.buf, { force = true })
        end
      end,
    })
  end

  local function raise_when_a_window_closes()
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      callback = function()
        error("a WinClosed handler of the user raised")
      end,
    })
  end

  local function fail_the_setup_and_then_raise_when(event)
    local failed = false
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = group,
      callback = function(args)
        if shows_the_proposal(args.buf) then
          failed = true
          error("a BufWinEnter handler of the user raised")
        end
      end,
    })
    vim.api.nvim_create_autocmd(event, {
      group = group,
      callback = function()
        if failed then
          error("a " .. event .. " handler of the user raised")
        end
      end,
    })
  end

  local function closes_the_new_tab_and_goes_back(arrange)
    local config = vim.deepcopy(require("claudecode.config").defaults)
    config.diff_opts.open_in_new_tab = true
    diff.setup(config)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    -- A tab on the right of the user's tab: `:tabclose` of the new tab lands there, so only the plugin's own step
    -- brings the cursor back to the tab it left.
    vim.cmd("tabnew")
    vim.cmd("tabfirst")
    local tabs, tab_before = vim.api.nvim_list_tabpages(), vim.api.nvim_get_current_tabpage()
    arrange()

    local call = tools.handle_invoke({ id = "failed_setup_guards_spec" }, {
      name = "openDiff",
      arguments = {
        old_file_path = path,
        new_file_path = path,
        new_file_contents = "alpha\nBETA\n",
        tab_name = tab_name,
      },
    })

    assert.is_nil(call._deferred, "the setup failed")
    assert.equal(-32000, call.error.code)
    assert.equal("Diff setup failed", call.error.message)
    assert.same(tabs, vim.api.nvim_list_tabpages(), "the new tab is closed")
    assert.equal(tab_before, vim.api.nvim_get_current_tabpage(), "the cursor is back in the tab it left")
  end

  before_each(function()
    vim.o.columns, vim.o.lines = 160, 40
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    path = dir .. "/a.txt"
    vim.fn.writefile({ "alpha", "beta" }, path)
    vim.api.nvim_create_augroup(group, { clear = true })
    tools.register_all()
    _G.claude_deferred_responses = {}
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, group)
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  it("closes the new tab and goes back to the tab it left when a WinClosed handler raises", function()
    closes_the_new_tab_and_goes_back(function()
      wipe_the_proposal_when_shown()
      raise_when_a_window_closes()
    end)
  end)

  it("closes the new tab and goes back when a WinLeave handler raises during the cleanup", function()
    closes_the_new_tab_and_goes_back(function()
      fail_the_setup_and_then_raise_when("WinLeave")
    end)
  end)

  it("closes the new tab and goes back when a BufLeave handler raises during the cleanup", function()
    closes_the_new_tab_and_goes_back(function()
      fail_the_setup_and_then_raise_when("BufLeave")
    end)
  end)
end)
