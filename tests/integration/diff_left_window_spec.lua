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

  local function open_diff(path)
    path = path or file
    diff.setup({ terminal = { provider = "none" }, diff_opts = { layout = "vertical" } })
    local call = tools.handle_invoke({ id = "left_window_spec" }, {
      name = "openDiff",
      arguments = { old_file_path = path, new_file_path = path, new_file_contents = "one\nTWO\n", tab_name = tab },
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
    vim.fn.writefile({ "fourth" }, dir .. "/fourth.txt")
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

  describe("diff mode that the user sets in the window that left the diff", function()
    local function leave_original_window_on_third()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      assert.equal("TAB_CLOSED", close_tab().result.content[1].text)
      return state
    end

    local function tab_diff_windows(tabpage)
      local count = 0
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        if option(win, "diff") then
          count = count + 1
        end
      end
      return count
    end

    it("keeps the options that the user set after ending diff mode in the window themselves", function()
      local state = open_diff()
      run_in(state.target_window, "diffoff")
      run_in(state.target_window, "setlocal foldmethod=indent scrollbind")
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      close_tab()

      run_in(state.target_window, "edit #")

      assert.equal(file, shows(state.target_window))
      assert.is_false(option(state.target_window, "diff"))
      assert.equal("indent", option(state.target_window, "foldmethod"), "the user's 'foldmethod' stays")
      assert.is_true(option(state.target_window, "scrollbind"), "the user's 'scrollbind' stays")
    end)

    local entries = {
      {
        name = "a :noautocmd command",
        enter = function(win, buffer)
          run_in(win, "noautocmd buffer " .. buffer)
        end,
      },
      {
        name = "an autocmd that does not nest",
        enter = function(win, buffer)
          vim.api.nvim_create_autocmd("User", {
            pattern = "ClaudeCodeSpecShowFile",
            once = true,
            callback = function()
              vim.api.nvim_win_set_buf(win, buffer)
            end,
          })
          vim.cmd("doautocmd User ClaudeCodeSpecShowFile")
        end,
      },
    }

    local function own_diff_after_entry_without_event(entry)
      local state = leave_original_window_on_third()
      run_in(state.target_window, "vsplit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      vim.cmd("diffthis")
      entry.enter(state.target_window, vim.fn.bufnr(file))
      assert.equal(file, shows(state.target_window), "the file is back in the window")
      run_in(state.target_window, "diffoff")
      run_in(state.target_window, "diffthis")
      return state
    end

    for _, entry in ipairs(entries) do
      it("keeps a diff the user started after " .. entry.name .. " showed the file without a BufWinEnter", function()
        local state = own_diff_after_entry_without_event(entry)

        vim.cmd("tabnew " .. vim.fn.fnameescape(file))

        assert.is_true(option(state.target_window, "diff"), "the user's diff stays")
      end)

      it("keeps that diff when the file leaves the window and comes back after " .. entry.name, function()
        local state = own_diff_after_entry_without_event(entry)

        run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
        run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

        assert.is_true(option(state.target_window, "diff"), "the user's diff comes back with the file")
      end)

      for _, reload in ipairs({ "edit", "edit!" }) do
        it("keeps that diff when the user runs :" .. reload .. " in the window after " .. entry.name, function()
          local state = own_diff_after_entry_without_event(entry)

          run_in(state.target_window, reload)

          assert.is_true(option(state.target_window, "diff"), "the user's diff stays")
        end)
      end
    end

    it("keeps that diff when the file enters a window of another tab first and nothing shows an event after", function()
      local state = own_diff_after_entry_without_event(entries[1])
      vim.cmd("tabnew " .. vim.fn.fnameescape(file))
      vim.cmd("tabclose")

      run_in(state.target_window, "noautocmd edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

      assert.is_true(option(state.target_window, "diff"), "the user's diff comes back with the file")
    end)

    it("leaves the diff mode of a window that opened as a copy of the user's diff window", function()
      local state = leave_original_window_on_third()
      run_in(state.target_window, "vsplit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      vim.cmd("diffthis")
      run_in(state.target_window, "noautocmd buffer " .. vim.fn.bufnr(file))
      run_in(state.target_window, "diffoff")
      run_in(state.target_window, "diffthis")
      run_in(state.target_window, "split " .. vim.fn.fnameescape(file))
      local copy = vim.api.nvim_get_current_win()

      assert.is_true(option(copy, "diff"), "the new window keeps the diff mode it copied")
      assert.is_true(option(state.target_window, "diff"), "the user's diff stays")
    end)

    it("keeps waiting when the file enters a window of another tab, and ends the diff mode there", function()
      local state = leave_original_window_on_third()
      local first_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew " .. vim.fn.fnameescape(file))
      local second_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd("diffthis")
      vim.cmd("vsplit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      vim.cmd("diffthis")
      vim.api.nvim_set_current_tabpage(first_tab)

      run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

      assert.is_false(option(state.target_window, "diff"), "diff mode is off in the waiting window")
      assert.equal(2, tab_diff_windows(second_tab), "the user's diff in the other tab stays")
    end)

    it("keeps the diff of the other windows in the tab when the file comes back", function()
      local state = leave_original_window_on_third()
      vim.cmd("vsplit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      local second = vim.api.nvim_get_current_win()
      vim.cmd("diffthis")
      vim.cmd("split " .. vim.fn.fnameescape(dir .. "/fourth.txt"))
      local third = vim.api.nvim_get_current_win()
      vim.cmd("diffthis")

      run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

      assert.is_false(option(state.target_window, "diff"), "diff mode is off in the returning window")
      assert.is_true(option(second, "diff"), "the user's diff stays in the first of its windows")
      assert.is_true(option(third, "diff"), "the user's diff stays in the second of its windows")
    end)

    it(
      "ends the diff mode that comes back with the file in a window the user had put in a diff of another buffer",
      function()
        local state = leave_original_window_on_third()
        run_in(state.target_window, "diffthis")
        vim.cmd("vsplit " .. vim.fn.fnameescape(dir .. "/other.txt"))
        local other_window = vim.api.nvim_get_current_win()
        vim.cmd("diffthis")

        run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

        assert.is_false(option(state.target_window, "diff"), "the saved diff mode does not come back")
        assert.is_true(option(other_window, "diff"), "the diff of the other window stays")
      end
    )
  end)

  describe("a new window for the file after a diff window left it", function()
    it("takes no diff mode from the proposal window that left, and the next diff stays in the tab", function()
      local state = open_diff()
      run_in(state.new_window, "edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      wait_for_answers(1)
      close_tab()

      run_in(state.new_window, "split " .. vim.fn.fnameescape(file))
      local new_window = vim.api.nvim_get_current_win()

      assert.equal(file, shows(new_window))
      for _, name in ipairs(diff_mode_options) do
        assert.equal(
          option(state.new_window, name),
          option(new_window, name),
          "'" .. name .. "' is as in the kept window"
        )
      end
      answers = {}
      local second = open_diff()
      assert.is_falsy(second.created_new_tab, "the next diff opens in this tab")
      assert.equal("TAB_CLOSED", close_tab().result.content[1].text)
      assert.is_true(vim.api.nvim_win_is_valid(new_window), "the user's window stays")
      assert.is_true(vim.api.nvim_win_is_valid(state.new_window), "the kept window stays")
    end)

    it("takes no diff mode from the original-side window that left", function()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      close_tab()

      run_in(state.target_window, "split " .. vim.fn.fnameescape(file))

      assert.is_false(option(vim.api.nvim_get_current_win(), "diff"), "diff mode is off in the new window")
      assert.equal(0, diff_windows(), "no window is in diff mode")
    end)

    local function spy_on_floats()
      local spy = { opened = {}, closed = {}, created = 0 }
      local real_open_win = vim.api.nvim_open_win
      vim.api.nvim_open_win = function(buffer, enter, config)
        local win = real_open_win(buffer, enter, config)
        spy.opened[#spy.opened + 1] = win
        return win
      end
      local group = vim.api.nvim_create_augroup("ClaudeCodeSpecFloatSpy", { clear = true })
      vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(args)
          spy.closed[#spy.closed + 1] = tonumber(args.match)
        end,
      })
      vim.api.nvim_create_autocmd("WinNew", {
        group = group,
        callback = function()
          spy.created = spy.created + 1
        end,
      })
      spy.stop = function()
        vim.api.nvim_open_win = real_open_win
        vim.api.nvim_del_augroup_by_id(group)
      end
      return spy
    end

    it("opens no float when every window of the diff showed the file", function()
      open_diff()
      local spy = spy_on_floats()

      close_tab()
      spy.stop()

      assert.equal(0, #spy.opened)
    end)

    it("shows the file in one float and closes it without a trace", function()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      vim.o.eventignore = "CursorHold"
      local spy = spy_on_floats()

      close_tab()
      spy.stop()
      local ignored = vim.o.eventignore
      vim.o.eventignore = ""

      assert.equal(1, #spy.opened)
      assert.is_false(vim.api.nvim_win_is_valid(spy.opened[1]), "the float is closed")
      assert.is_false(vim.tbl_contains(spy.closed, spy.opened[1]), "no WinClosed event for the float")
      assert.equal(0, spy.created, "no WinNew event for the float")
      assert.equal("CursorHold", ignored, "'eventignore' is as it was")
    end)

    it("takes the options that the user set after ending diff mode in the window that left", function()
      local state = open_diff()
      run_in(state.target_window, "diffoff")
      run_in(state.target_window, "setlocal foldmethod=indent scrollbind")
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      close_tab()

      run_in(state.target_window, "split " .. vim.fn.fnameescape(file))
      local new_window = vim.api.nvim_get_current_win()

      assert.equal("indent", option(new_window, "foldmethod"), "the user's 'foldmethod' goes to the new window")
      assert.is_true(option(new_window, "scrollbind"), "the user's 'scrollbind' goes to the new window")
    end)

    it("does not load a file buffer that the user unloaded", function()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      local buffer = vim.fn.bufnr(file)
      vim.cmd("bunload " .. buffer)

      close_tab()

      assert.is_false(vim.api.nvim_buf_is_loaded(buffer), "the cleanup leaves the buffer unloaded")
    end)

    it("does not wipe a file buffer that wipes itself when it is hidden", function()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      local buffer = vim.fn.bufnr(file)
      vim.bo[buffer].bufhidden = "wipe"

      close_tab()

      assert.is_true(vim.api.nvim_buf_is_valid(buffer), "the buffer is still there")
    end)
  end)

  describe("the hook that waits for the file", function()
    local function file_hooks()
      local entries = vim.api.nvim_get_autocmds({
        event = { "BufWinEnter", "BufLeave", "BufUnload" },
        buffer = vim.fn.bufnr(file),
      })
      assert.equal(0, #entries % 3, "each hook has an entry for each of its three events")
      return #entries / 3
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

    it("leaves one hook for the file after many diffs that each left a window that closed", function()
      for round = 1, 5 do
        local state = open_diff()
        run_in(state.new_window, "edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
        wait_for_answers(round)
        close_tab()
        vim.api.nvim_win_close(state.new_window, true)
      end
      assert.equal(1, file_hooks(), "the hooks of the earlier diffs went when the later diffs opened")

      vim.cmd("vsplit " .. vim.fn.fnameescape(file))

      assert.equal(0, file_hooks(), "the hook went when the file showed up")
    end)

    it("waits again for a later diff of the file after the first hook has run", function()
      for _ = 1, 2 do
        local state = open_diff()
        run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
        close_tab()
        assert.equal(1, file_hooks(), "a hook waits for the file")

        run_in(state.target_window, "edit #")

        assert.is_false(option(state.target_window, "diff"), "diff mode is off in the window")
        assert.equal(0, file_hooks(), "the hook went")
        answers = {}
      end
    end)
  end)
end)
