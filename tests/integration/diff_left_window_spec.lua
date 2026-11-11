-- Neovim saves a window's options for a buffer that leaves it and restores them when the buffer returns, so only a real
-- Neovim shows whether diff mode comes back after the diff ended.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("diff mode in a window that left a split diff", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("diff mode in a window that left a split diff", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local tab = "✻ [Claude Code] left_window.txt ⧉"
  local dir, file, answers

  local function open_diff()
    diff.setup({ terminal = { provider = "none" }, diff_opts = { layout = "vertical" } })
    local call = tools.handle_invoke({ id = "left_window_spec" }, {
      name = "openDiff",
      arguments = { old_file_path = file, new_file_path = file, new_file_contents = "one\nTWO\n", tab_name = tab },
    })
    assert.is_true(call._deferred, "openDiff waits for the user")
    _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
      answers[#answers + 1] = response
    end
    return diff._get_active_diffs()[tab]
  end

  local function run_in(win, command)
    vim.api.nvim_set_current_win(win)
    local ok, err = pcall(vim.cmd, command)
    assert.is_true(ok, ":" .. command .. " failed: " .. tostring(err))
  end

  local function wait_for_answers(count)
    vim.wait(1000, function()
      return #answers >= count
    end)
  end

  local function close_tab()
    local response = tools.handle_invoke(
      { id = "left_window_spec" },
      { name = "close_tab", arguments = { tab_name = tab } }
    )
    vim.wait(50)
    return response
  end

  local function shows(win)
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  end

  local function option(win, name)
    return vim.api.nvim_get_option_value(name, { win = win })
  end

  local diff_mode_options = { "diff", "scrollbind", "cursorbind", "foldmethod", "foldcolumn", "wrap" }

  local function diff_windows()
    local count = 0
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if option(win, "diff") then
        count = count + 1
      end
    end
    return count
  end

  before_each(function()
    vim.o.columns, vim.o.lines = 160, 40
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    file = dir .. "/existing.txt"
    vim.fn.writefile({ "one", "two" }, file)
    vim.fn.writefile({ "other" }, dir .. "/other.txt")
    vim.fn.writefile({ "third" }, dir .. "/third.txt")
    tools.register_all()
    _G.claude_deferred_responses = {}
    answers = {}
    vim.cmd("edit " .. vim.fn.fnameescape(file))
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  describe("the proposal window that :edit switched to another file", function()
    local state

    before_each(function()
      state = open_diff()
      run_in(state.new_window, "edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      wait_for_answers(1)
      assert.equal("TAB_CLOSED", close_tab().result.content[1].text)
      assert.equal(dir .. "/other.txt", shows(state.new_window), "close_tab keeps the window the user switched")
      assert.is_false(option(state.new_window, "diff"), "the switch ended diff mode there")
    end)

    it("stays out of diff mode when :edit brings the file back", function()
      run_in(state.new_window, "edit " .. vim.fn.fnameescape(file))

      assert.equal(file, shows(state.new_window))
      assert.is_false(option(state.new_window, "diff"), "diff mode is off in the window")
      assert.equal(0, diff_windows(), "no window is in diff mode")
    end)

    it("stays out of diff mode when :edit brings the file back and :only left that window alone", function()
      run_in(state.new_window, "only")
      run_in(state.new_window, "edit " .. vim.fn.fnameescape(file))

      assert.equal(1, #vim.api.nvim_list_wins())
      assert.is_false(option(state.new_window, "diff"), "diff mode is off in the window")
    end)

    it("gets back the options that diff mode changed, not only 'diff'", function()
      local kept = {}
      for _, name in ipairs(diff_mode_options) do
        kept[name] = option(state.new_window, name)
      end
      run_in(state.new_window, "edit " .. vim.fn.fnameescape(file))

      for _, name in ipairs(diff_mode_options) do
        assert.equal(kept[name], option(state.new_window, name), "'" .. name .. "' is as in the kept window")
      end
    end)

    it("lets the next diff of the file open in this tab, and close_tab keeps the user's windows", function()
      run_in(state.new_window, "only")
      run_in(state.new_window, "edit " .. vim.fn.fnameescape(file))
      answers = {}

      local second = open_diff()
      assert.is_falsy(second.created_new_tab, "the next diff opens in this tab")
      assert.equal(1, #vim.api.nvim_list_tabpages())
      assert.equal("TAB_CLOSED", close_tab().result.content[1].text)

      assert.equal(1, #vim.api.nvim_list_tabpages())
      assert.is_true(vim.api.nvim_win_is_valid(state.new_window), "the user's window stays")
    end)
  end)

  describe("the window on the original side that the user switched", function()
    it("stays out of diff mode when :edit # brings the file back after close_tab", function()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      assert.equal("TAB_CLOSED", close_tab().result.content[1].text)
      assert.equal(dir .. "/third.txt", shows(state.target_window), "close_tab keeps the window the user switched")

      run_in(state.target_window, "edit #")

      assert.equal(file, shows(state.target_window))
      assert.is_false(option(state.target_window, "diff"), "diff mode is off in the window")
      assert.equal(0, diff_windows(), "no window is in diff mode")
    end)

    it("gets back the options that diff mode changed, not only 'diff'", function()
      local before = {}
      for _, name in ipairs(diff_mode_options) do
        before[name] = option(0, name)
      end
      local state = open_diff()
      assert.is_true(option(state.target_window, "scrollbind"), "the diff set 'scrollbind'")
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      close_tab()

      run_in(state.target_window, "edit #")

      for _, name in ipairs(diff_mode_options) do
        assert.equal(before[name], option(state.target_window, name), "'" .. name .. "' is as before the diff")
      end
    end)

    it("shows the file out of diff mode when the user showed the proposal there and close_tab deletes it", function()
      local state = open_diff()
      run_in(state.target_window, "buffer " .. state.new_buffer)
      assert.equal("TAB_CLOSED", close_tab().result.content[1].text)

      assert.equal(1, #vim.api.nvim_list_wins(), "only the user's window is left")
      assert.equal(file, shows(vim.api.nvim_get_current_win()))
      assert.is_false(option(0, "diff"), "diff mode is off in the last window")
      assert.equal(0, diff_windows(), "no window is in diff mode")
    end)
  end)

  describe("a window that the diff never left", function()
    it("loses diff mode when close_tab runs, the same as before", function()
      local state = open_diff()
      assert.equal("TAB_CLOSED", close_tab().result.content[1].text)

      assert.is_false(option(state.target_window, "diff"))
      assert.equal(0, diff_windows())
    end)
  end)

  describe("the hook that waits for the file", function()
    local function file_hooks()
      return #vim.api.nvim_get_autocmds({ event = "BufWinEnter", buffer = vim.fn.bufnr(file) })
    end

    it("is gone once the file is back in the window", function()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      close_tab()
      assert.equal(1, file_hooks(), "one hook waits for the file")

      run_in(state.target_window, "edit #")

      assert.equal(0, file_hooks(), "the hook removed itself")
    end)

    it("is not left behind by a diff whose windows all showed the file at close_tab", function()
      open_diff()
      close_tab()

      assert.equal(0, file_hooks())
    end)

    it("removes itself when the file shows up after the window it waited for was closed", function()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      close_tab()
      vim.cmd("vsplit")
      vim.api.nvim_win_close(state.target_window, true)

      vim.cmd("split " .. vim.fn.fnameescape(file))

      assert.equal(0, file_hooks(), "the hook saw the closed window")
    end)
  end)
end)
