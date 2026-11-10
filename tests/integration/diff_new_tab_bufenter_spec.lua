if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff in a new tab: terminal BufEnter handler", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openDiff in a new tab: terminal BufEnter handler", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local dir, terminal_buf, job

  local client = { id = "bufenter_spec_client" }

  local function tab_name(n)
    return "✻ [Claude Code] bufenter " .. n .. " ⧉"
  end

  local function open_diff(n)
    local path = dir .. "/file" .. n .. ".txt"
    vim.fn.writefile({ "alpha" }, path)
    local call = tools.handle_invoke(client, {
      name = "openDiff",
      arguments = {
        old_file_path = path,
        new_file_path = path,
        new_file_contents = "alpha " .. n .. "\n",
        tab_name = tab_name(n),
      },
    })
    assert.is_true(call._deferred, vim.inspect(call.error))
  end

  local function close_diff(n)
    tools.handle_invoke(client, { name = "close_tab", arguments = { tab_name = tab_name(n) } })
  end

  local function count_terminal_handlers()
    local handlers = {}
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "BufEnter", group = "ClaudeCodeMCPDiff" })) do
      if autocmd.buflocal and autocmd.buffer == terminal_buf then
        table.insert(handlers, autocmd)
      end
    end
    return #handlers
  end

  local function find_terminal_window_in_current_tab()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
      if vim.api.nvim_win_get_buf(win) == terminal_buf then
        return win
      end
    end
    return nil
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    tools.register_all()
    _G.claude_deferred_responses = {}

    vim.cmd("botright vsplit")
    local terminal_win = vim.api.nvim_get_current_win()
    terminal_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(terminal_win, terminal_buf)
    job = vim.fn.termopen({ "sleep", "60" })
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

  local layouts = { "vertical", "unified" }

  for _, layout in ipairs(layouts) do
    describe("with layout = " .. layout, function()
      before_each(function()
        local config = vim.deepcopy(require("claudecode.config").defaults)
        config.diff_opts.layout = layout
        config.diff_opts.open_in_new_tab = true
        diff.setup(config)
      end)

      it("keeps one handler for each open diff and none after the last diff closes", function()
        assert.equal(0, count_terminal_handlers())

        open_diff(1)
        assert.equal(1, count_terminal_handlers())
        open_diff(2)
        assert.equal(2, count_terminal_handlers())
        open_diff(3)
        assert.equal(3, count_terminal_handlers())

        close_diff(3)
        assert.equal(2, count_terminal_handlers())
        close_diff(1)
        assert.equal(1, count_terminal_handlers())
        close_diff(2)
        assert.equal(0, count_terminal_handlers())
      end)

      it("drops the handler of a diff whose tab the user closed", function()
        open_diff(1)
        assert.equal(1, count_terminal_handlers())

        vim.cmd("tabclose!")

        assert.equal(0, count_terminal_handlers())
        close_diff(1)
        assert.equal(0, count_terminal_handlers())
      end)

      it("keeps the handler while the diff tab's terminal window shows another buffer, until it closes", function()
        open_diff(1)
        assert.equal(1, count_terminal_handlers())

        local diff_tab_terminal_win = find_terminal_window_in_current_tab()
        assert.is_not_nil(diff_tab_terminal_win, "the diff tab shows the terminal in a window")

        -- The user opens another file in the diff tab's terminal window. Entering that buffer fires BufEnter.
        vim.api.nvim_set_current_win(diff_tab_terminal_win)
        vim.api.nvim_win_set_buf(diff_tab_terminal_win, vim.api.nvim_create_buf(true, false))
        assert.is_nil(find_terminal_window_in_current_tab(), "the diff tab no longer shows the terminal")
        assert.equal(1, count_terminal_handlers())

        -- Leaving and entering windows fires more BufEnter events. The handler stays until its window closes.
        vim.cmd("wincmd p")
        vim.cmd("wincmd p")
        assert.equal(1, count_terminal_handlers())

        vim.api.nvim_win_close(diff_tab_terminal_win, true)
        assert.equal(0, count_terminal_handlers())
      end)
    end)
  end

  it("drops the handler when diff setup fails after the new tab was made (vertical)", function()
    local config = vim.deepcopy(require("claudecode.config").defaults)
    config.diff_opts.open_in_new_tab = true
    diff.setup(config)
    local real = diff._create_diff_view_from_window
    diff._create_diff_view_from_window = function()
      error("simulated failure after the new tab")
    end

    local path = dir .. "/failing.txt"
    vim.fn.writefile({ "alpha" }, path)
    local call = tools.handle_invoke(client, {
      name = "openDiff",
      arguments = { old_file_path = path, new_file_path = path, new_file_contents = "x\n", tab_name = tab_name(9) },
    })
    diff._create_diff_view_from_window = real

    assert.is_not_nil(call.error)
    assert.equal(1, vim.fn.tabpagenr("$"))
    assert.equal(0, count_terminal_handlers())
  end)

  it("drops the handler when diff setup fails after the new tab was made (unified)", function()
    local config = vim.deepcopy(require("claudecode.config").defaults)
    config.diff_opts.layout = "unified"
    config.diff_opts.open_in_new_tab = true
    diff.setup(config)
    local real = diff._resize_terminal_for_diff
    diff._resize_terminal_for_diff = function()
      error("simulated failure after the new tab")
    end

    local path = dir .. "/failing.txt"
    vim.fn.writefile({ "alpha" }, path)
    local call = tools.handle_invoke(client, {
      name = "openDiff",
      arguments = { old_file_path = path, new_file_path = path, new_file_contents = "x\n", tab_name = tab_name(9) },
    })
    diff._resize_terminal_for_diff = real

    assert.is_not_nil(call.error)
    assert.equal(1, vim.fn.tabpagenr("$"))
    assert.equal(0, count_terminal_handlers())
  end)
end)
