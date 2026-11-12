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

  local function open_diff(path, name)
    path = path or file
    name = name or tab
    diff.setup({ terminal = { provider = "none" }, diff_opts = { layout = "vertical" } })
    local call = tools.handle_invoke({ id = "left_window_spec" }, {
      name = "openDiff",
      arguments = { old_file_path = path, new_file_path = path, new_file_contents = "one\nTWO\n", tab_name = name },
    })
    assert.is_true(call._deferred, "openDiff waits for the user")
    _G.claude_deferred_responses[tostring(call.coroutine)] = function(response)
      answers[#answers + 1] = response
    end
    return diff._get_active_diffs()[name]
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

  local function close_tab(name)
    local response = tools.handle_invoke(
      { id = "left_window_spec" },
      { name = "close_tab", arguments = { tab_name = name or tab } }
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
    tools.setup()
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
    -- The plugin splits the window before it runs `diffthis`, so the options that Neovim saves for the file when the
    -- split shows the proposal have no diff mode.
    it("stays out of diff mode when :edit brings the file back", function()
      local state = open_diff()
      run_in(state.new_window, "edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      wait_for_answers(1)
      assert.equal("TAB_CLOSED", close_tab().result.content[1].text)
      assert.is_false(option(state.new_window, "diff"), "the switch ended diff mode there")

      run_in(state.new_window, "edit " .. vim.fn.fnameescape(file))

      assert.is_false(option(state.new_window, "diff"), "Neovim saved no diff mode for the file in this window")
      assert.equal(0, diff_windows())
    end)

    it("stays out of diff mode in the proposal window of the legacy diff when :edit brings the file back", function()
      -- The legacy diff.open_diff writes its proposal under stdpath("cache"); keep that out of the real cache folder.
      local saved_cache_home = vim.env.XDG_CACHE_HOME
      vim.env.XDG_CACHE_HOME = dir .. "/cache"
      diff.setup({ terminal = { provider = "none" }, diff_opts = { layout = "vertical" } })
      diff.open_diff(file, file, "one\nTWO\n", "legacy")
      local proposal = vim.api.nvim_get_current_win()
      assert.equal(2, diff_windows(), "the legacy diff compares two windows")

      run_in(proposal, "edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      run_in(proposal, "edit " .. vim.fn.fnameescape(file))
      vim.env.XDG_CACHE_HOME = saved_cache_home
      local diff_mode = option(proposal, "diff")
      vim.cmd("silent! diffoff!")

      assert.is_false(diff_mode, "Neovim saved no diff mode for the file in this window")
    end)
  end)

  describe("a file that comes back after the cleanup, which the cleanup does not look at (as on main)", function()
    it(
      "turns diff mode on again in the original window that :edit switched, when :edit # brings the file back",
      function()
        local state = open_diff()
        run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
        close_tab()

        run_in(state.target_window, "edit #")

        assert.is_true(option(state.target_window, "diff"), "Neovim sets the options that it saved for the file")
      end
    )

    it("gives a new window for the file the diff mode that the window that left saved", function()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      close_tab()

      run_in(state.target_window, "split " .. vim.fn.fnameescape(file))

      assert.is_true(option(vim.api.nvim_get_current_win(), "diff"), "the new window takes the saved set")
    end)

    it("leaves a ClaudeCodeDiffClosed handler's diff and options alone when the file enters a window later", function()
      local state = open_diff()
      run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
      vim.api.nvim_create_autocmd("User", {
        pattern = "ClaudeCodeDiffClosed",
        once = true,
        callback = function()
          run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))
          vim.cmd("diffoff")
          vim.cmd("diffthis")
          vim.cmd("setlocal foldmethod=indent scrollbind nowrap")
        end,
      })
      close_tab()

      vim.cmd("tabnew " .. vim.fn.fnameescape(file))

      assert.is_true(option(state.target_window, "diff"), "the handler's diff mode stays")
      assert.equal("indent", option(state.target_window, "foldmethod"), "the handler's 'foldmethod' stays")
      assert.is_true(option(state.target_window, "scrollbind"), "the handler's 'scrollbind' stays")
      assert.is_false(option(state.target_window, "wrap"), "the handler's 'wrap' stays")
    end)

    it(
      "answers close_tab from the command-line window, where Neovim refuses diffoff, and leaves the copy as it is",
      function()
        local state = open_diff()
        run_in(state.target_window, "split " .. vim.fn.fnameescape(file))
        local copy = vim.api.nvim_get_current_win()
        run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
        local outcome
        vim.api.nvim_create_autocmd("CmdwinEnter", {
          once = true,
          callback = function()
            outcome = { pcall(close_tab) }
          end,
        })

        vim.api.nvim_feedkeys("q:", "x", false)

        assert.is_true(outcome[1], "close_tab did not raise")
        assert.equal("TAB_CLOSED", outcome[2].result.content[1].text)
        assert.is_nil(diff._get_active_diffs()[tab], "the diff is closed")
        assert.is_true(option(copy, "diff"), "Neovim refused diffoff in the command-line window")
      end
    )
  end)

  describe("the window on the original side that the user switched", function()
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

  describe("the windows of the original side's tab page that show the file when the cleanup looks", function()
    it("keeps the diff mode of a copy of the file that has a partner window", function()
      local state = open_diff()
      run_in(state.target_window, "split " .. vim.fn.fnameescape(file))
      local copy = vim.api.nvim_get_current_win()
      vim.cmd("vsplit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      local partner = vim.api.nvim_get_current_win()
      vim.cmd("diffthis")

      close_tab()

      assert.is_true(option(copy, "diff"), "the copy has a partner")
      assert.is_true(option(partner, "diff"), "the partner stays")
    end)

    it("keeps the diff mode of two copies of the file that the user compares", function()
      local state = open_diff()
      run_in(state.target_window, "split " .. vim.fn.fnameescape(file))
      local first = vim.api.nvim_get_current_win()
      vim.cmd("split " .. vim.fn.fnameescape(file))
      local second = vim.api.nvim_get_current_win()

      close_tab()

      assert.is_true(option(first, "diff"), "each copy is the other's partner")
      assert.is_true(option(second, "diff"), "each copy is the other's partner")
    end)

    it("leaves the options of a copy that is not in diff mode alone", function()
      local state = open_diff()
      run_in(state.target_window, "split " .. vim.fn.fnameescape(file))
      local copy = vim.api.nvim_get_current_win()
      vim.cmd("diffoff")
      vim.cmd("setlocal foldmethod=indent scrollbind nowrap")

      close_tab()

      assert.equal("indent", option(copy, "foldmethod"), "the user's 'foldmethod' stays")
      assert.is_true(option(copy, "scrollbind"), "the user's 'scrollbind' stays")
      assert.is_false(option(copy, "wrap"), "the user's 'wrap' stays")
    end)

    it("closes a diff whose original-side window the plugin opened and closes", function()
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      local state = open_diff()
      assert.is_true(state.target_window_created_by_plugin, "the plugin opened its own window for the file")

      assert.equal("TAB_CLOSED", close_tab().result.content[1].text)

      assert.is_false(vim.api.nvim_win_is_valid(state.target_window), "the window that the plugin opened is closed")
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

    -- OptionSet does not fire in this spec, which plenary starts with -c, so a window that gets diff mode by a
    -- command looks like a copy here. diff_cleanup_events_spec.lua runs the cases with a command.
    it("ends the diff mode of a lone window of another tab that copied it from the original window", function()
      local state = open_diff()
      local first_tab = vim.api.nvim_get_current_tabpage()
      run_in(state.target_window, "tab split")
      local other_tab_window = vim.api.nvim_get_current_win()
      assert.is_true(option(other_tab_window, "diff"), "the new tab copied diff mode from the original window")
      vim.api.nvim_set_current_tabpage(first_tab)

      close_tab()

      assert.is_false(option(other_tab_window, "diff"), "the copy has no partner left")
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

    it(
      "ends diff mode in the window of this tab, and not in the current window, when close_tab runs from another tab",
      function()
        local state = open_diff()
        run_in(state.target_window, "split " .. vim.fn.fnameescape(file))
        local copy = vim.api.nvim_get_current_win()
        assert.is_true(option(copy, "diff"), "the copy joined the diff")
        vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/other.txt"))
        local user_first = vim.api.nvim_get_current_win()
        vim.cmd("diffthis")
        vim.cmd("vsplit " .. vim.fn.fnameescape(dir .. "/fourth.txt"))
        local user_second = vim.api.nvim_get_current_win()
        vim.cmd("diffthis")
        vim.api.nvim_set_current_win(user_first)

        close_tab()

        assert.is_false(option(copy, "diff"), "the copy has no partner left")
        assert.is_true(option(user_first, "diff"), "the user's diff in the current tab stays")
        assert.is_true(option(user_second, "diff"), "the user's diff in the current tab stays")
      end
    )

    it(
      "keeps a diff that a ClaudeCodeDiffClosed handler starts in the window it gave the file, when the file enters a window later",
      function()
        local state = open_diff()
        run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
        vim.api.nvim_create_autocmd("User", {
          pattern = "ClaudeCodeDiffClosed",
          once = true,
          callback = function()
            run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))
            vim.cmd("diffoff")
            vim.cmd("diffthis")
            vim.cmd("setlocal foldmethod=indent scrollbind nowrap")
          end,
        })
        close_tab()
        assert.is_true(option(state.target_window, "diff"), "the handler's diff mode is on")

        vim.cmd("tabnew " .. vim.fn.fnameescape(file))

        assert.is_true(option(state.target_window, "diff"), "the handler's diff mode stays")
        assert.equal("indent", option(state.target_window, "foldmethod"), "the handler's 'foldmethod' stays")
        assert.is_true(option(state.target_window, "scrollbind"), "the handler's 'scrollbind' stays")
        assert.is_false(option(state.target_window, "wrap"), "the handler's 'wrap' stays")
      end
    )

    it("keeps a diff that a ClaudeCodeDiffClosed handler starts, and the options that the handler sets", function()
      local state = open_diff()
      vim.api.nvim_create_autocmd("User", {
        pattern = "ClaudeCodeDiffClosed",
        once = true,
        callback = function()
          run_in(state.target_window, "diffthis")
          run_in(state.target_window, "setlocal foldmethod=indent scrollbind nowrap")
        end,
      })

      close_tab()

      assert.is_true(option(state.target_window, "diff"), "the handler's diff mode stays")
      assert.equal("indent", option(state.target_window, "foldmethod"), "the handler's 'foldmethod' stays")
      assert.is_true(option(state.target_window, "scrollbind"), "the handler's 'scrollbind' stays")
      assert.is_false(option(state.target_window, "wrap"), "the handler's 'wrap' stays")

      run_in(state.target_window, "vsplit " .. vim.fn.fnameescape(dir .. "/fourth.txt"))
      vim.cmd("diffthis")

      assert.equal(2, diff_windows(), "the comparison that the handler started has both windows")
    end)

    it(
      "keeps a diff of the file with itself that the user started, because each window is the other's partner",
      function()
        local state = wait_with_a_second_waiting_window()
        close_tab()
        run_in(state.target_window, "edit " .. vim.fn.fnameescape(file))
        vim.cmd("diffthis")

        vim.cmd("split " .. vim.fn.fnameescape(file))
        local copy = vim.api.nvim_get_current_win()

        assert.is_true(option(copy, "diff"), "the new window keeps the diff mode that it copied")
        assert.is_true(option(state.target_window, "diff"), "the window that it was split from keeps diff mode")
      end
    )
  end)
  describe("two diffs of the same file", function()
    local second_tab = "✻ [Claude Code] left_window.txt (second) ⧉"

    it("keeps the second diff's windows in diff mode when the first diff closes", function()
      local first = open_diff()
      run_in(first.new_window, "quit")
      wait_for_answers(1)
      local second = open_diff(file, second_tab)
      assert.equal(first.target_window, second.target_window, "the second diff reuses the original-side window")
      assert.is_true(option(second.target_window, "diff"))

      assert.equal("TAB_CLOSED", close_tab().result.content[1].text)

      assert.is_true(vim.api.nvim_win_is_valid(second.target_window), "the window of the second diff stays")
      assert.is_true(option(second.target_window, "diff"), "the first diff leaves the second diff's window alone")
      assert.is_true(option(second.new_window, "diff"), "the second diff's proposal stays in diff mode")

      assert.equal("TAB_CLOSED", close_tab(second_tab).result.content[1].text)
      assert.equal(0, diff_windows(), "the second diff ends its own diff mode")
    end)

    it("keeps the second diff's original-side window open when the first diff opened that window", function()
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
      local first = open_diff()
      assert.is_true(first.target_window_created_by_plugin, "the first diff opened its own window for the file")
      run_in(first.new_window, "quit")
      wait_for_answers(1)
      local second = open_diff(file, second_tab)
      assert.equal(first.target_window, second.target_window, "the second diff reuses that window")

      close_tab()

      assert.is_true(vim.api.nvim_win_is_valid(second.target_window), "the first diff does not close it")
      assert.is_true(option(second.target_window, "diff"))
      assert.is_true(option(second.new_window, "diff"))
    end)

    it("ends both diffs' diff mode when the second one closes first", function()
      local first = open_diff()
      run_in(first.new_window, "quit")
      wait_for_answers(1)
      open_diff(file, second_tab)

      close_tab(second_tab)
      close_tab()

      assert.equal(0, diff_windows())
    end)
  end)
end)
