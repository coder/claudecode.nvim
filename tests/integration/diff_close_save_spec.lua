if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("closing and saving a proposed diff", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("closing and saving a proposed diff", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local tab = "✻ [Claude Code] close_save.txt ⧉"
  local dir, answers, notices, real_notify

  local function open_diff(layout, file, diff_opts)
    diff.setup({
      terminal = { provider = "none" },
      diff_opts = vim.tbl_extend("force", { layout = layout }, diff_opts or {}),
    })
    local call = tools.handle_invoke({ id = "close_save_spec" }, {
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

  local function settle()
    vim.wait(50)
  end

  local function wait_for_answers(count)
    vim.wait(1000, function()
      return #answers >= count
    end)
  end

  local function close_tab()
    return tools.handle_invoke({ id = "close_save_spec" }, { name = "close_tab", arguments = { tab_name = tab } })
  end

  -- `:qa` stops with E37 or E162 on a modified buffer, except nofile and nowrite buffers, such as the new-file
  -- placeholder.
  local function buffers_that_stop_qa()
    local names = {}
    for _, info in ipairs(vim.fn.getbufinfo({ bufmodified = 1 })) do
      if not vim.tbl_contains({ "nofile", "nowrite" }, vim.bo[info.bufnr].buftype) then
        names[#names + 1] = info.name
      end
    end
    return names
  end

  local function window_showing(file)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == file then
        return win
      end
    end
  end

  before_each(function()
    vim.o.columns, vim.o.lines = 160, 40
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "one", "two" }, dir .. "/existing.txt")
    vim.fn.writefile({ "other" }, dir .. "/other.txt")
    vim.fn.writefile({ "third" }, dir .. "/third.txt")
    tools.register_all()
    _G.claude_deferred_responses = {}
    answers = {}
    notices = {}
    real_notify = vim.notify
    vim.notify = function(message, level)
      notices[#notices + 1] = { message = message, level = level }
    end
  end)

  after_each(function()
    vim.notify = real_notify
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    vim.o.signcolumn = "auto"
    _G.claude_deferred_responses = nil
  end)

  local layouts = { "vertical" }
  if vim.fn.has("nvim-0.9") == 1 then
    layouts[#layouts + 1] = "unified"
  else
    describe("in the unified layout", function()
      pending("the unified layout needs Neovim 0.9")
    end)
  end

  for _, layout in ipairs(layouts) do
    local files = {
      { name = "an existing file", file = "existing.txt", open = "existing.txt" },
      { name = "a new file, with another file open", file = "fresh.txt", open = "existing.txt" },
      { name = "a new file, in an empty editor", file = "fresh.txt" },
    }
    for _, target in ipairs(files) do
      describe("in the " .. layout .. " layout, for " .. target.name, function()
        local function propose(diff_opts)
          if target.open then
            vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. target.open))
          end
          return open_diff(layout, dir .. "/" .. target.file, diff_opts)
        end

        local saves = {
          { name = ":wq", command = "wq" },
          { name = ":x", command = "x" },
          { name = "ZZ", command = "normal! ZZ" },
        }
        for _, save in ipairs(saves) do
          it(save.name .. " accepts the proposal, closes its window and leaves no unsaved buffer", function()
            local state = propose()

            run_in(state.new_window, save.command)
            settle()

            assert.equal(1, #answers, "one answer")
            assert.equal("FILE_SAVED", answers[1].content[1].text)
            assert.equal("one\nTWO\n", answers[1].content[2].text)
            assert.equal("saved", diff._get_active_diffs()[tab].status)
            assert.is_false(vim.api.nvim_win_is_valid(state.new_window), save.name .. " closed the diff window")
            assert.same({}, buffers_that_stop_qa(), ":qa would stop at a modified buffer (E37 or E162)")
            assert.equal("TAB_CLOSED", close_tab().result.content[1].text)
            assert.equal(1, #answers, "close_tab does not answer openDiff a second time")
          end)
        end

        it("a second :w neither fails nor answers openDiff again", function()
          local state = propose()
          run_in(state.new_window, "write")
          assert.equal(1, #answers)

          run_in(state.new_window, "write")
          settle()

          assert.equal(1, #answers, "one answer for one openDiff")
          assert.equal("saved", diff._get_active_diffs()[tab].status)
          assert.is_true(vim.api.nvim_win_is_valid(state.new_window), ":w keeps the window until close_tab")
          assert.same({}, notices, "a repeat :w with nothing new to send says nothing")
        end)

        it(":wq after :w closes the window and answers once", function()
          local state = propose()
          run_in(state.new_window, "write")

          run_in(state.new_window, "wq")
          settle()

          assert.equal(1, #answers, "one answer for one openDiff")
          assert.is_false(vim.api.nvim_win_is_valid(state.new_window), ":wq closed the diff window")
        end)

        it(":ClaudeCodeDiffAccept leaves no unsaved buffer, and a :w after it answers nothing", function()
          local state = propose()
          vim.api.nvim_set_current_win(state.new_window)
          diff.accept_current_diff()
          assert.equal(1, #answers)
          assert.same({}, buffers_that_stop_qa(), ":qa would stop at a modified buffer (E37 or E162)")

          run_in(state.new_window, "write")

          assert.equal(1, #answers, "one answer for one openDiff")
        end)

        it("leaves no unsaved buffer after the :q rejects, so :qa can quit before close_tab", function()
          local state = propose()
          run_in(state.new_window, "quit")
          wait_for_answers(1)
          settle()

          assert.equal("DIFF_REJECTED", answers[1].content[1].text)
          assert.same({}, buffers_that_stop_qa(), ":qa would stop at a modified buffer (E37 or E162)")
        end)

        it("leaves no unsaved buffer after :ClaudeCodeDiffDeny", function()
          local state = propose()
          vim.api.nvim_set_current_win(state.new_window)
          diff.deny_current_diff()

          assert.equal("DIFF_REJECTED", answers[1].content[1].text)
          assert.same({}, buffers_that_stop_qa(), ":qa would stop at a modified buffer (E37 or E162)")
        end)

        local is_new = target.file == "fresh.txt"
        local reject_modes = is_new and { "keep_empty", "close_window" } or { "keep_empty" }
        for _, reject_mode in ipairs(reject_modes) do
          local suffix = is_new and (", with on_new_file_reject " .. reject_mode) or ""
          it("keeps the window that :edit switched to another buffer" .. suffix, function()
            local other = dir .. "/other.txt"
            vim.o.signcolumn = "no"
            local state = propose({ on_new_file_reject = reject_mode })

            run_in(state.new_window, "edit " .. vim.fn.fnameescape(other))
            wait_for_answers(1)
            settle()
            assert.equal("DIFF_REJECTED", answers[1].content[1].text)
            assert.equal(state.new_window, window_showing(other), "the reject keeps the user's window")

            close_tab()
            settle()

            assert.equal(state.new_window, window_showing(other), "close_tab keeps the user's window")
            assert.equal(other, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(state.new_window)))
            assert.is_true(vim.api.nvim_buf_is_loaded(vim.fn.bufnr(other)), "the user's buffer stays")
            assert.equal(
              "no",
              vim.api.nvim_get_option_value("signcolumn", { win = state.new_window }),
              "the window gets its 'signcolumn' back"
            )
            assert.equal(1, #answers, "one answer for one openDiff")
          end)

          it("keeps the 'signcolumn' that the user set in the window that :edit switched" .. suffix, function()
            local other = dir .. "/other.txt"
            vim.o.signcolumn = "no"
            local state = propose({ on_new_file_reject = reject_mode })
            run_in(state.new_window, "edit " .. vim.fn.fnameescape(other))
            wait_for_answers(1)
            run_in(state.new_window, "setlocal signcolumn=yes:2")

            close_tab()
            settle()

            assert.equal(state.new_window, window_showing(other), "close_tab keeps the user's window")
            assert.equal(
              "yes:2",
              vim.api.nvim_get_option_value("signcolumn", { win = state.new_window }),
              "the user's own 'signcolumn' stays"
            )

            run_in(state.new_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
            assert.equal(
              "no",
              vim.api.nvim_get_option_value("signcolumn", { win = state.new_window }),
              "a buffer that the window shows later gets the window's default, not the diff's 'yes' or the user's value"
            )
          end)
        end
      end)
    end

    it(
      "closes the proposal window with :wq in a diff of its own tab, and close_tab closes the tab in the "
        .. layout
        .. " layout",
      function()
        local file = dir .. "/existing.txt"
        vim.cmd("edit " .. vim.fn.fnameescape(file))
        local state = open_diff(layout, file, { open_in_new_tab = true })
        assert.equal(2, #vim.api.nvim_list_tabpages())

        run_in(state.new_window, "wq")
        settle()

        assert.equal("FILE_SAVED", answers[1].content[1].text)
        assert.is_false(vim.api.nvim_win_is_valid(state.new_window), ":wq closed the proposal window")
        assert.equal("TAB_CLOSED", close_tab().result.content[1].text)
        assert.equal(1, #vim.api.nvim_list_tabpages(), "close_tab closed the diff's tab")
        assert.equal(1, #answers, "one answer for one openDiff")
      end
    )

    if layout == "vertical" then
      it("keeps the window on the original side that the user switched to another buffer", function()
        vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
        local state = open_diff(layout, dir .. "/existing.txt")
        assert.is_true(state.target_window_created_by_plugin, "the diff opened a window of its own for the file")
        local third = dir .. "/third.txt"
        run_in(state.target_window, "edit " .. vim.fn.fnameescape(third))

        run_in(state.new_window, "quit")
        wait_for_answers(1)
        close_tab()
        settle()

        assert.equal(state.target_window, window_showing(third), "close_tab keeps the user's window")
      end)

      -- `:edit other.txt` turns 'diff' off by itself. Going back to the file's own buffer does not, because that
      -- buffer is still in diff mode in the other window, so only the cleanup can end the diff mode in the kept window.
      it("turns off diff mode in a proposal window that :edit # switched back to the file", function()
        local file = dir .. "/existing.txt"
        vim.cmd("edit " .. vim.fn.fnameescape(file))
        local state = open_diff(layout, file)
        run_in(state.new_window, "edit #")
        wait_for_answers(1)
        assert.is_true(vim.api.nvim_get_option_value("diff", { win = state.new_window }), "the switch keeps diff mode")

        close_tab()
        settle()

        assert.equal(file, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(state.new_window)), "close_tab keeps it")
        assert.is_false(vim.api.nvim_get_option_value("diff", { win = state.new_window }), "diff mode ends there")
      end)

      it(
        "keeps the diff mode that the user turned on in the proposal window that :edit switched in the "
          .. layout
          .. " layout",
        function()
          local file = dir .. "/existing.txt"
          vim.cmd("edit " .. vim.fn.fnameescape(file))
          local state = open_diff(layout, file)
          run_in(state.new_window, "edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
          wait_for_answers(1)
          run_in(state.new_window, "setlocal diff")

          close_tab()
          settle()

          assert.is_true(
            vim.api.nvim_get_option_value("diff", { win = state.new_window }),
            "the user's diff mode stays"
          )
        end
      )

      it(
        "keeps the diff mode that the user turned on in the original-side window that :edit switched in the "
          .. layout
          .. " layout",
        function()
          vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
          local state = open_diff(layout, dir .. "/existing.txt")
          assert.is_true(state.target_window_created_by_plugin, "the diff opened a window of its own for the file")
          run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/third.txt"))
          run_in(state.target_window, "diffthis")
          run_in(state.target_window, "belowright split " .. vim.fn.fnameescape(dir .. "/other.txt"))
          vim.cmd("diffthis")

          run_in(state.new_window, "quit")
          wait_for_answers(1)
          close_tab()
          settle()

          assert.is_true(
            vim.api.nvim_get_option_value("diff", { win = state.target_window }),
            "the user's diff mode stays"
          )
        end
      )
    end

    if layout == "unified" then
      it(
        "keeps the diff mode that the user turned on in the proposal window that :edit switched in the "
          .. layout
          .. " layout",
        function()
          local file = dir .. "/existing.txt"
          vim.cmd("edit " .. vim.fn.fnameescape(file))
          local state = open_diff(layout, file)
          run_in(state.new_window, "edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
          wait_for_answers(1)
          run_in(state.new_window, "diffthis")
          run_in(state.target_window, "diffthis")

          close_tab()
          settle()

          assert.is_true(
            vim.api.nvim_get_option_value("diff", { win = state.new_window }),
            "the user's diff mode stays"
          )
        end
      )

      it(
        "keeps the diff mode that the user turned on in the proposal window that :edit # switched back in the "
          .. layout
          .. " layout",
        function()
          local file = dir .. "/existing.txt"
          vim.cmd("edit " .. vim.fn.fnameescape(file))
          local state = open_diff(layout, file)
          run_in(state.new_window, "edit #")
          wait_for_answers(1)
          assert.equal(
            file,
            vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(state.new_window)),
            "the switch went back"
          )
          run_in(state.target_window, "edit " .. vim.fn.fnameescape(dir .. "/other.txt"))
          run_in(state.new_window, "diffthis")
          run_in(state.target_window, "diffthis")

          close_tab()
          settle()

          assert.is_true(
            vim.api.nvim_get_option_value("diff", { win = state.new_window }),
            "the user's diff mode stays"
          )
        end
      )
    end

    if layout == "vertical" then
      it(
        "warns in the vertical layout when :w follows edits made after the accept, because Claude never gets them",
        function()
          local file = dir .. "/existing.txt"
          vim.cmd("edit " .. vim.fn.fnameescape(file))
          local state = open_diff(layout, file)
          run_in(state.new_window, "write")
          vim.api.nvim_buf_set_lines(state.new_buffer, 0, -1, false, { "late edit" })

          run_in(state.new_window, "write")
          settle()

          assert.equal(1, #answers, "one answer for one openDiff")
          assert.equal(1, #notices)
          assert.equal(vim.log.levels.WARN, notices[1].level)
          assert.matches("already accepted", notices[1].message)
          assert.same({}, buffers_that_stop_qa(), "the write is handled, so :wq can close the window")
        end
      )
    end
  end
end)
