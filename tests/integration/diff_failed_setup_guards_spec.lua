-- Real-Neovim guards for openDiff with `diff_opts.open_in_new_tab`: when the diff setup fails after `:tabnew` and a
-- handler of the user raises while the plugin cleans up, openDiff still answers "Diff setup failed", closes the tab
-- it opened and goes back to the tab it left, and Neovim keeps running. Under busted's mock vim this is pending;
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

  local function reset()
    pcall(vim.api.nvim_del_augroup_by_name, group)
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
  end

  after_each(function()
    reset()
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
    if jit then
      jit.opt.start("hotloop=56", "hotexit=10", "tryside=4") -- LuaJIT's defaults
    end
  end)

  local function a_WinClosed_handler_raises()
    wipe_the_proposal_when_shown()
    raise_when_a_window_closes()
  end

  local function a_WinLeave_handler_raises_during_the_cleanup()
    fail_the_setup_and_then_raise_when("WinLeave")
  end

  local function a_BufLeave_handler_raises_during_the_cleanup()
    fail_the_setup_and_then_raise_when("BufLeave")
  end

  it("closes the new tab and goes back to the tab it left when a WinClosed handler raises", function()
    closes_the_new_tab_and_goes_back(a_WinClosed_handler_raises)
  end)

  it("closes the new tab and goes back when a WinLeave handler raises during the cleanup", function()
    closes_the_new_tab_and_goes_back(a_WinLeave_handler_raises_during_the_cleanup)
  end)

  it("closes the new tab and goes back when a BufLeave handler raises during the cleanup", function()
    closes_the_new_tab_and_goes_back(a_BufLeave_handler_raises_during_the_cleanup)
  end)

  -- A LuaJIT older than 2023-09-21 (the release builds of Neovim 0.8 and 0.9) has a bug (LuaJIT issue #1066): after a
  -- C function runs Lua on another thread and then raises into a pcall, the next exit from a compiled trace crashes. A
  -- Neovim API call that raises inside a coroutine because a handler it ran raised is that case. Neovim then aborts
  -- (exit 134, "bad stack slot") or crashes (exit 139), and plenary prints no summary. openDiff runs in a coroutine
  -- (tools.handle_invoke). On such a LuaJIT, utils.resume_tool_coroutine turns the JIT off and flushes its traces
  -- before it resumes that coroutine. Without that guard, the three cases above can hit the bug too, but far less often
  -- than this case. A JIT that compiles at once makes the passes below hit it in most runs, so this case fails on
  -- Neovim 0.8 and 0.9 when the guard is missing.
  it("keeps Neovim running when handlers raise on repeated failed setups under an eager JIT", function()
    if jit then
      jit.opt.start("hotloop=1", "hotexit=1", "tryside=1")
    end
    local arrangements = {
      a_WinClosed_handler_raises,
      a_WinLeave_handler_raises_during_the_cleanup,
      a_BufLeave_handler_raises_during_the_cleanup,
    }
    for pass = 1, 6 do
      vim.api.nvim_create_augroup(group, { clear = true })
      closes_the_new_tab_and_goes_back(arrangements[pass % #arrangements + 1])
      reset()
    end
  end)
end)
