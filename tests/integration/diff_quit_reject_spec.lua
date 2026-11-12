-- Real-Neovim checks that closing a proposed diff's window with :q, or switching that window to another buffer,
-- rejects the diff and answers openDiff, in the split and the unified layout.
-- Mock vim cannot run Neovim's own :q, so under busted this is pending.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("leaving a proposed diff", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("leaving a proposed diff", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local tab = "✻ [Claude Code] quit.txt ⧉"
  local dir, path, answers

  local function open_diff(layout, diff_opts)
    diff.setup({
      terminal = { provider = "none" },
      diff_opts = vim.tbl_extend("force", { layout = layout }, diff_opts or {}),
    })
    local call = tools.handle_invoke({ id = "quit_reject_spec" }, {
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

  local function texts(response)
    return { response.content[1].text, response.content[2].text }
  end

  local function wait_for_answers(count)
    vim.wait(1000, function()
      return #answers >= count
    end)
  end

  local function settle()
    vim.wait(50)
  end

  local function close_tab()
    return tools.handle_invoke({ id = "quit_reject_spec" }, { name = "close_tab", arguments = { tab_name = tab } })
  end

  before_each(function()
    vim.o.columns, vim.o.lines = 160, 40
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    path = dir .. "/quit.txt"
    vim.fn.writefile({ "one", "two" }, path)
    tools.register_all()
    _G.claude_deferred_responses = {}
    answers = {}
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  for _, layout in ipairs({ "vertical", "unified" }) do
    describe("in the " .. layout .. " layout", function()
      it("answers DIFF_REJECTED at once and closes the diff window", function()
        local state = open_diff(layout)
        assert.same({}, answers, "openDiff waits for the user")

        run_in(state.new_window, "quit")

        assert.same({ { "DIFF_REJECTED", tab } }, vim.tbl_map(texts, answers))
        assert.equal("rejected", diff._get_active_diffs()[tab].status)
        assert.is_false(vim.api.nvim_win_is_valid(state.new_window), "the :q closed the diff window")
        settle()
        assert.equal(1, #answers, "the window close and the hidden buffer answer once together")
      end)

      it("sends no second answer when the user quits after saving with :w", function()
        local state = open_diff(layout)
        run_in(state.new_window, "write")
        assert.equal(1, #answers)
        assert.equal("FILE_SAVED", answers[1].content[1].text)

        run_in(state.new_window, "quit")

        assert.equal(1, #answers, "one answer for one openDiff")
        assert.equal("saved", diff._get_active_diffs()[tab].status)
        assert.is_false(vim.api.nvim_win_is_valid(state.new_window), "the :q closed the diff window")
      end)

      it("keeps waiting while another window shows the proposal, and rejects when the last one closes", function()
        local state = open_diff(layout)
        vim.api.nvim_set_current_win(state.new_window)
        vim.cmd("split")
        local clone = vim.api.nvim_get_current_win()
        assert.are_not.equal(state.new_window, clone)
        assert.equal(state.new_buffer, vim.api.nvim_win_get_buf(clone))

        run_in(clone, "quit")
        assert.same({}, answers, "a window still shows the proposal")
        assert.equal("pending", diff._get_active_diffs()[tab].status)

        run_in(state.new_window, "quit")
        assert.same({ { "DIFF_REJECTED", tab } }, vim.tbl_map(texts, answers))
      end)

      local function other_file()
        local other = dir .. "/other.txt"
        vim.fn.writefile({ "other" }, other)
        return other
      end

      local switches = {
        { name = ":edit", run = "edit %s" },
        { name = ":edit!", run = "edit! %s" },
        { name = ":buffer", run = "buffer %s" },
        { name = ":enew", run = "enew" },
        { name = ":enew!", run = "enew!" },
      }
      for _, switch in ipairs(switches) do
        it("answers DIFF_REJECTED when " .. switch.name .. " switches the proposal window to another buffer", function()
          local other = other_file()
          local state = open_diff(layout)
          local command = switch.run
          if command:find("%%s") then
            vim.cmd("badd " .. vim.fn.fnameescape(other))
            command = command:format(switch.name == ":buffer" and vim.fn.bufnr(other) or vim.fn.fnameescape(other))
          end

          run_in(state.new_window, command)
          wait_for_answers(1)

          assert.same({ { "DIFF_REJECTED", tab } }, vim.tbl_map(texts, answers))
          assert.equal("rejected", diff._get_active_diffs()[tab].status)
          assert.equal(0, #vim.fn.win_findbuf(state.new_buffer), "no window shows the proposal")
          settle()
          assert.equal(1, #answers, "one answer for one openDiff")
          assert.equal("TAB_CLOSED", close_tab().result.content[1].text)
        end)
      end

      it("keeps waiting while another window shows the proposal after one switches to another buffer", function()
        local other = other_file()
        local state = open_diff(layout)
        vim.api.nvim_set_current_win(state.new_window)
        vim.cmd("split")
        local clone = vim.api.nvim_get_current_win()

        run_in(clone, "edit " .. vim.fn.fnameescape(other))
        settle()
        assert.same({}, answers, "a window still shows the proposal")
        assert.equal("pending", diff._get_active_diffs()[tab].status)

        run_in(state.new_window, "quit")
        assert.same({ { "DIFF_REJECTED", tab } }, vim.tbl_map(texts, answers))
      end)

      it("keeps waiting when the proposal is shown again before the loop turn ends", function()
        local other = other_file()
        local state = open_diff(layout)

        run_in(state.new_window, ("edit %s | buffer %d"):format(vim.fn.fnameescape(other), state.new_buffer))
        settle()

        assert.same({}, answers, "the window shows the proposal again")
        assert.equal("pending", diff._get_active_diffs()[tab].status)
      end)

      it("does not reject a diff that replaced the one whose window switched buffers", function()
        local other = other_file()
        local state = open_diff(layout)
        run_in(state.new_window, "edit " .. vim.fn.fnameescape(other))

        local replacement = open_diff(layout)
        settle()

        assert.are_not.equal(state.new_buffer, replacement.new_buffer)
        assert.equal(1, #answers, "only the replaced diff got its answer")
        assert.equal("pending", diff._get_active_diffs()[tab].status)
      end)

      it("answers DIFF_REJECTED for a diff in its own tab, and close_tab closes the tab", function()
        local state = open_diff(layout, { open_in_new_tab = true })
        assert.equal(2, #vim.api.nvim_list_tabpages())

        run_in(state.new_window, "quit")

        assert.same({ { "DIFF_REJECTED", tab } }, vim.tbl_map(texts, answers))
        local closed = close_tab()
        assert.equal("TAB_CLOSED", closed.result.content[1].text)
        assert.is_nil(diff._get_active_diffs()[tab])
        assert.equal(1, #vim.api.nvim_list_tabpages(), "close_tab closed the diff's tab")
      end)

      it("lets close_tab clean up after the :q", function()
        local state = open_diff(layout)
        run_in(state.new_window, "quit")

        local closed = close_tab()

        assert.equal("TAB_CLOSED", closed.result.content[1].text)
        assert.is_nil(diff._get_active_diffs()[tab])
        assert.is_false(vim.api.nvim_buf_is_valid(state.new_buffer), "the proposal buffer is gone")
        assert.equal(1, #vim.api.nvim_tabpage_list_wins(0), "only the user's window is left")
        assert.equal(1, #answers, "close_tab does not answer openDiff a second time")
      end)
    end)
  end
end)
