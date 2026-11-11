if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff when the diff setup fails", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openDiff when the diff setup fails", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local tab = "✻ [Claude Code] proposal ⧉"
  local group = "diff_failed_setup_leftovers_spec"
  local tabnew_group = "diff_failed_setup_leftovers_spec_tabnew"
  local dir, real_hidden

  local function path(name)
    return dir .. "/" .. name
  end

  local function use(diff_opts)
    local config = vim.deepcopy(require("claudecode.config").defaults)
    config.diff_opts = vim.tbl_extend("force", config.diff_opts, diff_opts or {})
    diff.setup(config)
  end

  local function wipe_the_proposal_when_shown()
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = vim.api.nvim_create_augroup(group, { clear = true }),
      callback = function(args)
        if vim.api.nvim_buf_get_name(args.buf):find(tab, 1, true) then
          vim.api.nvim_buf_delete(args.buf, { force = true })
        end
      end,
    })
  end

  local function open_diff_that_fails(name, contents)
    local call = tools.handle_invoke({ id = "failed_setup_spec" }, {
      name = "openDiff",
      arguments = {
        old_file_path = path(name),
        new_file_path = path(name),
        new_file_contents = contents,
        tab_name = tab,
      },
    })
    assert.is_nil(call._deferred, "the setup failed")
    assert.equal(-32000, call.error.code)
    assert.equal("Diff setup failed", call.error.message)
    assert.is_nil(diff._get_active_diffs()[tab])
  end

  local function assert_still_there(wins, bufs)
    for _, win in ipairs(wins) do
      assert.is_true(vim.api.nvim_win_is_valid(win), "the window " .. win .. " was there before")
    end
    for _, buf in ipairs(bufs) do
      assert.is_true(vim.api.nvim_buf_is_valid(buf), "the buffer " .. buf .. " was there before")
    end
  end

  local function add_sidebar_hook_to_new_tab()
    local hook = {}
    vim.api.nvim_create_autocmd("TabNewEntered", {
      group = vim.api.nvim_create_augroup(tabnew_group, { clear = true }),
      once = true,
      callback = function()
        hook.win = vim.api.nvim_get_current_win()
        vim.bo.filetype = "neo-tree"
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved sidebar text" })
        vim.o.hidden = false
      end,
    })
    return hook
  end

  before_each(function()
    vim.o.columns, vim.o.lines = 160, 40
    real_hidden = vim.o.hidden
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "alpha", "beta" }, path("a.txt"))
    vim.fn.writefile({ "one", "two" }, path("b.txt"))
    tools.register_all()
    _G.claude_deferred_responses = {}
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, group)
    pcall(vim.api.nvim_del_augroup_by_name, tabnew_group)
    vim.o.hidden = real_hidden
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  it("closes the window that the setup split for an existing file's original side", function()
    use()
    vim.cmd("edit " .. vim.fn.fnameescape(path("b.txt")))
    local wins, bufs = vim.api.nvim_list_wins(), vim.api.nvim_list_bufs()
    wipe_the_proposal_when_shown()

    open_diff_that_fails("a.txt", "alpha\nBETA\n")

    assert.same(wins, vim.api.nvim_list_wins())
    assert_still_there(wins, bufs)
  end)

  it("deletes the (NEW FILE) buffer that a new file's setup made", function()
    use()
    vim.cmd("edit " .. vim.fn.fnameescape(path("b.txt")))
    local wins, bufs = vim.api.nvim_list_wins(), vim.api.nvim_list_bufs()
    wipe_the_proposal_when_shown()

    open_diff_that_fails("new.txt", "brand new\n")

    assert_still_there(wins, bufs)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      assert.is_nil(vim.api.nvim_buf_get_name(buf):find("(NEW FILE)", 1, true), "a (NEW FILE) buffer is left")
    end
  end)

  it("turns diff mode off in the user's window that an existing file's setup reused", function()
    use()
    vim.cmd("edit " .. vim.fn.fnameescape(path("a.txt")))
    local user_win = vim.api.nvim_get_current_win()
    local wins, bufs = vim.api.nvim_list_wins(), vim.api.nvim_list_bufs()
    wipe_the_proposal_when_shown()

    open_diff_that_fails("a.txt", "alpha\nBETA\n")

    assert.same(wins, vim.api.nvim_list_wins())
    assert_still_there(wins, bufs)
    assert.is_false(vim.wo[user_win].diff, "the window is still in diff mode")
  end)

  it("keeps the hook's window, not a split of it, when the new tab cannot be closed", function()
    use({ open_in_new_tab = true })
    vim.cmd("edit " .. vim.fn.fnameescape(path("a.txt")))
    local wins, bufs = vim.api.nvim_list_wins(), vim.api.nvim_list_bufs()
    local hook = add_sidebar_hook_to_new_tab()
    wipe_the_proposal_when_shown()

    open_diff_that_fails("a.txt", "alpha\nBETA\n")

    assert_still_there(wins, bufs)
    assert.equal(2, #vim.api.nvim_list_tabpages(), "the new tab could not be closed")
    assert.same({ hook.win }, vim.api.nvim_tabpage_list_wins(vim.api.nvim_list_tabpages()[2]))
  end)
end)
