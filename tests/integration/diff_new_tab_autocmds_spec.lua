if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("autocmds of the user while a diff tab that stays open is released", function()
    pending("needs a real Neovim")
  end)
  return
end

local helper = require("tests.helpers.new_tab_diff_child")

describe("autocmds of the user while a diff tab that stays open is released", function()
  local child = helper.new()

  after_each(child.stop)

  ---The diff is the only tab, as when the user closed the first one from the diff tab. With `cursor_in_terminal` the user
  ---left the diff tab's terminal in terminal-normal mode, so closing the diff moves the cursor out of it.
  local function open_in_last_tab(layout, cursor_in_terminal, start_options)
    child.start(vim.tbl_extend("force", { layout = layout }, start_options or {}))
    child.open_diff("a.txt", "first diff")
    if cursor_in_terminal then
      child.focus_terminal_in_tab()
      child.leave_terminal_mode()
    end
    child.call([[vim.cmd("1tabclose")]])
    assert.equal(1, child.state().tabs)
    child.call([[
      local diff_data = assert(require("claudecode.diff")._get_active_diffs()["first diff"])
      _G.proposal_win = diff_data.new_window
      _G.proposal_buf = diff_data.new_buffer
      _G.terminal_win = diff_data.terminal_win_in_new_tab
    ]])
  end

  ---An edited file of the user's in a window of its own above the terminal. The cursor stays where it is.
  local function open_user_window()
    return child.call([[
      vim.fn.writefile({ "one", "two" }, _G.dir .. "/other.txt")
      vim.api.nvim_win_call(_G.terminal_win, function()
        vim.cmd("split " .. vim.fn.fnameescape(_G.dir .. "/other.txt"))
        _G.user_win = vim.api.nvim_get_current_win()
      end)
      _G.user_buf = vim.api.nvim_win_get_buf(_G.user_win)
      vim.api.nvim_buf_set_lines(_G.user_buf, 0, -1, false, { "user changed one", "user kept two" })
      return vim.api.nvim_buf_get_lines(_G.user_buf, 0, -1, false)
    ]])
  end

  ---An autocmd of the user's that runs `body` once. `_G.ran` is true afterwards. `options` is more of the autocmd's
  ---Lua table, such as `buffer = _G.proposal_buf,`.
  local function user_autocmd(event, body, options)
    child.call(string.format(
      [[
      _G.ran = false
      vim.api.nvim_create_autocmd(%q, {
        %s
        callback = function()
          if _G.ran then
            return
          end
          _G.ran = true
          %s
        end,
      })
    ]],
      event,
      options or "",
      body
    ))
  end

  ---Records every event that shows or leaves a window or a buffer, and whether the diff's terminal window and its proposal
  ---window were still open.
  local function record_events()
    child.call([[
      _G.fired = {}
      local diff_data = assert(require("claudecode.diff")._get_active_diffs()["first diff"])
      local events = { "BufEnter", "BufLeave", "WinEnter", "WinLeave", "BufNew", "BufAdd", "BufWinEnter", "BufWinLeave",
        "BufHidden", "WinClosed", "OptionSet", "TabEnter", "TabLeave" }
      for _, event in ipairs(events) do
        vim.api.nvim_create_autocmd(event, {
          callback = function()
            if event == "OptionSet" and vim.fn.expand("<amatch>") == "modified" then
              return
            end
            local terminal_open = vim.api.nvim_win_is_valid(diff_data.terminal_win_in_new_tab)
            local proposal_open = vim.api.nvim_win_is_valid(diff_data.new_window)
              and vim.api.nvim_win_get_buf(diff_data.new_window) == diff_data.new_buffer
            table.insert(_G.fired, {
              event = event,
              buffer = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
              terminal_open = terminal_open,
              proposal_open = proposal_open,
            })
          end,
        })
      end
    ]])
  end

  for _, layout in ipairs({ "vertical", "unified" }) do
    it("fires only WinEnter and BufEnter, once the proposal window is gone, with layout = " .. layout, function()
      open_in_last_tab(layout, true)
      record_events()

      child.close_diff("first diff")
      child.state()
      local fired = child.call([[return _G.fired]])

      local expected_buffer = layout == "vertical" and "a.txt" or ""
      assert.same({
        { event = "WinEnter", buffer = expected_buffer, terminal_open = true, proposal_open = false },
        { event = "BufEnter", buffer = expected_buffer, terminal_open = true, proposal_open = false },
      }, fired)
      assert.equal(0, child.leftovers().in_diff_mode)
    end)

    it(
      "fires only WinEnter and BufEnter, once the terminal window is gone too, when the user hid the terminal before the diff, with layout = "
        .. layout,
      function()
        open_in_last_tab(layout, true, { hide_original_terminal = true })
        record_events()

        child.close_diff("first diff")
        child.state()
        local fired = child.call([[return _G.fired]])

        local expected_buffer = layout == "vertical" and "a.txt" or ""
        assert.same({
          { event = "WinEnter", buffer = expected_buffer, terminal_open = false, proposal_open = false },
          { event = "BufEnter", buffer = expected_buffer, terminal_open = false, proposal_open = false },
        }, fired)
      end
    )

    it("fires no event when the cursor was in a window of the user's, with layout = " .. layout, function()
      open_in_last_tab(layout, false)
      open_user_window()
      child.call([[vim.api.nvim_set_current_win(_G.user_win)]])
      record_events()

      child.close_diff("first diff")
      child.state()

      assert.same({}, child.call([[return _G.fired]]))
      assert.is_true(child.call([[return vim.api.nvim_get_current_win() == _G.user_win]]))
    end)

    it(
      "starts no insert when an autocmd enters a terminal at the end, with Snacks' auto_insert, layout = " .. layout,
      function()
        open_in_last_tab(layout, true, { snacks_auto_insert = true, hide_original_terminal = true })
        user_autocmd(
          "WinEnter",
          [[
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "terminal" then
            vim.api.nvim_set_current_win(win)
          end
        end
      ]]
        )

        child.close_diff("first diff")
        local state = child.state()

        assert.is_true(child.call([[return _G.ran]]), "the WinEnter autocmd must run when the cursor moves")
        assert.equal("n", state.mode)
        assert.equal(0, child.leftovers().handlers)
      end
    )

    it("drops the terminal's handler before any autocmd runs, with layout = " .. layout, function()
      open_in_last_tab(layout, true)
      child.call([[
        vim.api.nvim_win_call(_G.terminal_win, function()
          vim.cmd("vsplit")
          _G.second_terminal_win = vim.api.nvim_get_current_win()
        end)
      ]])
      assert.equal(1, child.leftovers().handlers)
      user_autocmd("WinEnter", [[vim.api.nvim_set_current_win(_G.second_terminal_win)]], "nested = true,")

      child.close_diff("first diff")
      local state = child.state()

      assert.is_true(child.call([[return _G.ran]]), "the WinEnter autocmd must run when the cursor moves")
      assert.equal("nt", state.mode, "the diff's handler must not start terminal mode in the user's terminal window")
      assert.equal(0, child.leftovers().handlers)
    end)
  end

  it("fires only BufEnter for the empty buffer when the cursor stays in the proposal window", function()
    open_in_last_tab("unified", false)
    record_events()

    child.close_diff("first diff")
    child.state()

    assert.same(
      { { event = "BufEnter", buffer = "", terminal_open = true, proposal_open = false } },
      child.call([[return _G.fired]])
    )
  end)

  it(
    "moves the cursor to the window the diff stored for the file, not to a window of the user's by the terminal",
    function()
      open_in_last_tab("vertical", true)
      open_user_window()
      child.call([[_G.file_win = require("claudecode.diff")._get_active_diffs()["first diff"].target_window]])
      record_events()

      child.close_diff("first diff")
      child.state()

      assert.is_true(child.call([[return vim.api.nvim_get_current_win() == _G.file_win]]))
      assert.same({
        { event = "WinEnter", buffer = "a.txt", terminal_open = true, proposal_open = false },
        { event = "BufEnter", buffer = "a.txt", terminal_open = true, proposal_open = false },
      }, child.call([[return _G.fired]]))
    end
  )

  it("does not let a BufLeave autocmd of the proposal buffer switch its window during the swap", function()
    open_in_last_tab("unified", true)
    local before = open_user_window()
    user_autocmd(
      "BufLeave",
      [[
      vim.api.nvim_win_set_buf(_G.proposal_win, _G.user_buf)
      vim.api.nvim_win_set_cursor(_G.proposal_win, { 1, 0 })
    ]],
      "buffer = _G.proposal_buf,"
    )

    child.close_diff("first diff")
    child.state()
    local after = child.call([[
      return {
        ran = _G.ran,
        shown_buf = vim.api.nvim_win_get_buf(_G.proposal_win),
        user_buf = _G.user_buf,
        lines = vim.api.nvim_buf_get_lines(_G.user_buf, 0, -1, false),
      }
    ]])

    assert.is_false(after.ran, "no BufLeave autocmd may run while the release swaps the proposal buffer out")
    assert.not_equal(after.user_buf, after.shown_buf)
    assert.same(before, after.lines)
  end)

  it(
    "moves a cursor in the proposal window to the window the diff stored for the file, not to a window of the user's",
    function()
      open_in_last_tab("vertical", false)
      child.call([[
      vim.fn.writefile({ "one", "two" }, _G.dir .. "/other.txt")
      vim.api.nvim_win_call(_G.proposal_win, function()
        vim.cmd("split " .. vim.fn.fnameescape(_G.dir .. "/other.txt"))
        _G.user_win = vim.api.nvim_get_current_win()
      end)
      _G.file_win = require("claudecode.diff")._get_active_diffs()["first diff"].target_window
    ]])
      assert.is_true(child.call([[return vim.api.nvim_get_current_win() == _G.proposal_win]]))

      child.close_diff("first diff")
      local state = child.state()

      assert.is_true(child.call([[return vim.api.nvim_get_current_win() == _G.file_win]]))
      assert.equal("n", state.mode)
    end
  )
end)
