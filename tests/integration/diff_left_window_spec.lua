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

  describe("diff mode that the user sets in a window that left the diff", function()
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

    -- Ways to show a buffer in a window without a BufWinEnter, for the user's own diff to start without an event.
    local silent = {
      {
        name = "a :noautocmd command",
        show = function(win, buffer)
          run_in(win, "noautocmd buffer " .. buffer)
        end,
      },
      {
        name = "an autocmd that does not nest",
        show = function(win, buffer)
          vim.api.nvim_create_autocmd("User", {
            pattern = "ClaudeCodeSpecShow",
            once = true,
            callback = function()
              vim.api.nvim_win_set_buf(win, buffer)
            end,
          })
          vim.cmd("doautocmd User ClaudeCodeSpecShow")
        end,
      },
    }

    -- The original-side window left the file, a partner window shows other.txt in diff mode, the file comes back to
    -- the original-side window without an event, and the user starts a diff there with the partner.
    local function own_diff_after_silent_return(entry)
      local state = leave_original_window_on_third()
      run_in(state.target_window, "vsplit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      vim.cmd("diffthis")
      entry.show(state.target_window, vim.fn.bufnr(file))
      assert.equal(file, shows(state.target_window), "the file is back in the window")
      run_in(state.target_window, "diffoff")
      run_in(state.target_window, "diffthis")
      return state
    end

    for _, entry in ipairs(silent) do
      it(
        "keeps a diff the user started after " .. entry.name .. " showed the file, when it enters another tab",
        function()
          local state = own_diff_after_silent_return(entry)

          vim.cmd("tabnew " .. vim.fn.fnameescape(file))

          assert.is_true(option(state.target_window, "diff"), "the user's diff stays")
        end
      )

      it("keeps that diff when the file leaves the window and comes back after " .. entry.name, function()
        local state = own_diff_after_silent_return(entry)

        run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
        run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

        assert.is_true(option(state.target_window, "diff"), "the user's diff comes back with the file")
      end)

      it("keeps that diff when the file also leaves without an event, with " .. entry.name, function()
        local state = own_diff_after_silent_return(entry)

        entry.show(state.target_window, vim.fn.bufnr(dir .. "/third.txt"))
        run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

        assert.is_true(option(state.target_window, "diff"), "the user's diff comes back with the file")
      end)

      for _, reload in ipairs({ "edit", "edit!" }) do
        it("keeps that diff when the user runs :" .. reload .. " in the window after " .. entry.name, function()
          local state = own_diff_after_silent_return(entry)

          run_in(state.target_window, reload)

          assert.is_true(option(state.target_window, "diff"), "the user's diff stays")
        end)
      end
    end

    for _, event in ipairs({ "BufEnter", "BufWinEnter" }) do
      it("keeps a diff that the user's " .. event .. " autocmd starts when the file comes back", function()
        local state = open_diff()
        local started = false
        vim.api.nvim_create_autocmd(event, {
          buffer = vim.fn.bufnr(file),
          callback = function()
            if started then
              vim.cmd("diffoff")
              vim.cmd("diffthis")
            end
          end,
        })
        run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
        close_tab()
        run_in(state.target_window, "vsplit " .. vim.fn.fnameescape(dir .. "/other.txt"))
        vim.cmd("diffthis")
        started = true

        run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

        assert.is_true(option(state.target_window, "diff"), "the user's diff stays")
      end)
    end

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

    it("ends the leftover in a window when the diff of another tab has its partner there", function()
      local state = leave_original_window_on_third()
      local first_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew " .. vim.fn.fnameescape(file))
      local second_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd("diffthis")
      vim.cmd("vsplit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      vim.cmd("diffthis")
      vim.api.nvim_set_current_tabpage(first_tab)

      run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

      assert.is_false(option(state.target_window, "diff"), "diff mode is off in the window that was alone in its tab")
      assert.equal(2, tab_diff_windows(second_tab), "the user's diff in the other tab stays")
    end)

    it("keeps diff mode that returns into a tab with a diff of another buffer, which could be the user's", function()
      local state = leave_original_window_on_third()
      run_in(state.target_window, "diffthis")
      vim.cmd("vsplit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      local other_window = vim.api.nvim_get_current_win()
      vim.cmd("diffthis")

      run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

      assert.is_true(option(state.target_window, "diff"), "the window has a partner in diff mode")
      assert.is_true(option(other_window, "diff"), "the diff of the other window stays")
    end)
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

    it("ends the diff mode of the window that a script gives the file while another window is current", function()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      close_tab()
      vim.cmd("vsplit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      local current = vim.api.nvim_get_current_win()

      vim.api.nvim_win_set_buf(state.target_window, vim.fn.bufnr(file))

      assert.equal(current, vim.api.nvim_get_current_win(), "the current window did not change")
      assert.equal(file, shows(state.target_window))
      assert.is_false(option(state.target_window, "diff"), "diff mode is off in the window that got the file")
      assert.equal(0, diff_windows(), "no window is in diff mode")
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

    it("leaves a lone diff window of another tab alone when close_tab runs", function()
      local state = open_diff()
      local first_tab = vim.api.nvim_get_current_tabpage()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      vim.cmd("tabnew " .. vim.fn.fnameescape(file))
      local other_tab_window = vim.api.nvim_get_current_win()
      vim.cmd("diffthis")
      vim.api.nvim_set_current_tabpage(first_tab)

      close_tab()

      assert.is_true(option(other_tab_window, "diff"), "the window of the other tab is not touched")
    end)

    it("ends the diff mode of a window that already shows the file and has no partner after close_tab", function()
      local state = open_diff()
      run_in(state.target_window, "split " .. vim.fn.fnameescape(file))
      local copy = vim.api.nvim_get_current_win()
      assert.is_true(option(copy, "diff"), "the new window copied diff mode while the diff is open")

      close_tab()

      assert.is_false(option(copy, "diff"), "the window has no partner left")
      assert.equal(0, diff_windows(), "no window is in diff mode")
    end)
  end)

  describe("the window that gets the file", function()
    local function wait_with_a_second_waiting_window()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      run_in(state.new_window, "edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      wait_for_answers(1)
      return state
    end

    it("ends diff mode there when an earlier BufWinEnter handler moved the focus to a window of another tab", function()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      local moved_to
      vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = state.original_buffer,
        callback = function()
          if moved_to then
            vim.api.nvim_set_current_win(moved_to)
          end
        end,
      })
      close_tab()
      vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/other.txt"))
      moved_to = vim.api.nvim_get_current_win()
      vim.cmd("diffthis")

      run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

      assert.equal(moved_to, vim.api.nvim_get_current_win(), "the handler moved the focus")
      assert.equal(file, shows(state.target_window))
      assert.is_false(option(state.target_window, "diff"), "diff mode is off in the window that got the file")
      assert.is_true(option(moved_to, "diff"), "the diff of the other tab, which never got the file, stays")
    end)

    it("leaves a lone diff window of the file in another tab alone when the file enters a window", function()
      local state = open_diff()
      local first_tab = vim.api.nvim_get_current_tabpage()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      vim.cmd("tabnew " .. vim.fn.fnameescape(file))
      local other_tab_window = vim.api.nvim_get_current_win()
      vim.cmd("diffthis")
      vim.api.nvim_set_current_tabpage(first_tab)
      close_tab()

      run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))

      assert.is_false(option(state.target_window, "diff"), "diff mode is off in the window that got the file")
      assert.is_true(option(other_tab_window, "diff"), "the window that already showed the file is not touched")
    end)

    it(
      "looks at a window once, so a diff that the user starts there stays when the file enters another window",
      function()
        local state = wait_with_a_second_waiting_window()
        close_tab()
        run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))
        assert.is_false(option(state.target_window, "diff"), "diff mode is off in the window that got the file")
        vim.cmd("diffthis")
        assert.is_true(option(state.target_window, "diff"), "the user started a diff there")

        vim.cmd("tabnew " .. vim.fn.fnameescape(file))

        assert.is_true(option(state.target_window, "diff"), "the window is not looked at again")
      end
    )
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

    it("leaves no window waiting for the buffer of a new file that close_tab deletes", function()
      local state = open_diff(dir .. "/created.txt")
      assert.is_true(state.is_new_file, "the diff is of a file that does not exist")
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      local created_buffer = state.original_buffer

      close_tab()

      assert.is_false(vim.api.nvim_buf_is_valid(created_buffer), "close_tab deleted the buffer of the new file")
      assert.is_nil(vim.w[state.target_window].claudecode_file_windows, "no window waits for the deleted buffer")
    end)

    it("is one hook for the file however many diffs left a window behind", function()
      for round = 1, 5 do
        local state = open_diff()
        run_in(state.new_window, "edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
        wait_for_answers(round)
        close_tab()
        vim.api.nvim_win_close(state.new_window, true)
      end
      assert.equal(1, file_hooks(), "five diffs share one hook")

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
