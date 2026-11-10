-- Real-Neovim checks that :q on a proposed diff rejects it and answers openDiff, in the split and the unified layout.
-- Mock vim cannot run Neovim's own :q, so under busted this is pending.
if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("closing a proposed diff with :q", function()
    pending("needs a real Neovim")
  end)
  return
end

if vim.fn.has("nvim-0.9") ~= 1 then
  describe("closing a proposed diff with :q", function()
    pending("the unified layout needs Neovim 0.9")
  end)
  return
end

describe("closing a proposed diff with :q", function()
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

      it("answers DIFF_REJECTED for a diff in its own tab, and close_tab closes the tab", function()
        local state = open_diff(layout, { open_in_new_tab = true })
        assert.equal(2, #vim.api.nvim_list_tabpages())

        run_in(state.new_window, "quit")

        assert.same({ { "DIFF_REJECTED", tab } }, vim.tbl_map(texts, answers))
        local closed = tools.handle_invoke(
          { id = "quit_reject_spec" },
          { name = "close_tab", arguments = { tab_name = tab } }
        )
        assert.equal("TAB_CLOSED", closed.result.content[1].text)
        assert.is_nil(diff._get_active_diffs()[tab])
        assert.equal(1, #vim.api.nvim_list_tabpages(), "close_tab closed the diff's tab")
      end)

      it("lets close_tab clean up after the :q", function()
        local state = open_diff(layout)
        run_in(state.new_window, "quit")

        local closed = tools.handle_invoke(
          { id = "quit_reject_spec" },
          { name = "close_tab", arguments = { tab_name = tab } }
        )

        assert.equal("TAB_CLOSED", closed.result.content[1].text)
        assert.is_nil(diff._get_active_diffs()[tab])
        assert.is_false(vim.api.nvim_buf_is_valid(state.new_buffer), "the proposal buffer is gone")
        assert.equal(1, #vim.api.nvim_tabpage_list_wins(0), "only the user's window is left")
        assert.equal(1, #answers, "close_tab does not answer openDiff a second time")
      end)
    end)
  end
end)
