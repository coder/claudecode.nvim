if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("openDiff with a floating Claude terminal", function()
    pending("needs a real Neovim")
  end)
  return
end

describe("openDiff with a floating Claude terminal", function()
  local diff = require("claudecode.diff")
  local tools = require("claudecode.tools.init")
  local config_defaults = require("claudecode.config").defaults
  local dir
  local float

  local function visible_floats(tab)
    local wins = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab or vim.api.nvim_get_current_tabpage())) do
      local cfg = vim.api.nvim_win_get_config(win)
      if (cfg.relative or "") ~= "" and vim.api.nvim_win_get_buf(win) == float.buf and cfg.hide ~= true then
        wins[#wins + 1] = win
      end
    end
    return wins
  end

  local function install_float_terminal(opts)
    local fake = { hide_calls = 0, show_calls = 0, ensure_calls = 0 }
    fake.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(fake.buf, 0, -1, false, { "Claude terminal" })

    local function open_window()
      fake.win = vim.api.nvim_open_win(fake.buf, false, {
        relative = "editor",
        row = 1,
        col = 1,
        width = vim.o.columns - 4,
        height = vim.o.lines - 6,
      })
    end
    -- Neovim 0.10 can park a float with `hide`, as the Snacks provider does. Older Neovim closes it.
    local can_park = vim.fn.has("nvim-0.10") == 1
    local function window_is_open()
      return fake.win ~= nil
        and vim.api.nvim_win_is_valid(fake.win)
        and vim.api.nvim_win_get_config(fake.win).hide ~= true
    end
    local function hide_window()
      if can_park then
        vim.api.nvim_win_set_config(fake.win, { hide = true })
      else
        vim.api.nvim_win_close(fake.win, true)
        fake.win = nil
      end
    end
    -- Counts every show and hide, as the Snacks provider does. `hide_float` hands out the count as its token, and
    -- `restore_float` shows the float only while the count is the same. `opts.own_mark` makes a provider that
    -- follows the older contract instead: it returns `true`, ignores the token, and keeps its own mark of a hide
    -- that nothing has undone. That mark does not say which diff hid the float.
    local own_mark = opts and opts.own_mark
    fake.changes = 0
    fake.marked = false
    local function show_window()
      if fake.win and vim.api.nvim_win_is_valid(fake.win) then
        vim.api.nvim_win_set_config(fake.win, { hide = false })
      else
        open_window()
      end
    end

    function fake.user_hide()
      fake.marked = false
      if window_is_open() then
        fake.changes = fake.changes + 1
        hide_window()
      end
    end

    function fake.user_show()
      fake.marked = false
      fake.changes = fake.changes + 1
      show_window()
    end

    open_window()

    local provider = {
      setup = function() end,
      open = function() end,
      close = function() end,
      simple_toggle = function() end,
      focus_toggle = function() end,
      is_available = function()
        return true
      end,
      get_active_bufnr = function()
        return vim.api.nvim_buf_is_valid(fake.buf) and fake.buf or nil
      end,
      hide_float = function()
        if not window_is_open() then
          return false
        end
        hide_window()
        fake.changes = fake.changes + 1
        fake.marked = true
        fake.hide_calls = fake.hide_calls + 1
        if own_mark then
          return true
        end
        return fake.changes
      end,
      restore_float = function(token)
        local unchanged
        if own_mark then
          unchanged = fake.marked
        else
          unchanged = token == fake.changes
        end
        fake.marked = false
        if unchanged and not window_is_open() then
          fake.show_calls = fake.show_calls + 1
          show_window()
        end
      end,
      ensure_visible = function()
        if not window_is_open() then
          fake.ensure_calls = fake.ensure_calls + 1
          show_window()
        end
      end,
    }
    if opts and opts.without_hide_float then
      provider.hide_float = nil
      provider.restore_float = nil
    end
    package.loaded["claudecode.terminal"] = nil
    require("claudecode.terminal").setup({ provider = provider }, nil, nil)
    return fake
  end

  local function setup_diff(diff_opts)
    local cfg = vim.deepcopy(config_defaults)
    cfg.terminal = vim.tbl_extend("force", cfg.terminal or {}, { auto_insert = false })
    cfg.diff_opts = vim.tbl_extend("force", cfg.diff_opts or {}, diff_opts or {})
    diff.setup(cfg)
  end

  local function tab_name_of(file)
    return "✻ [Claude Code] " .. file .. " ⧉"
  end

  local function open_diff(file)
    local path = dir .. "/" .. file
    local call = tools.handle_invoke({ id = "float_spec_" .. file }, {
      name = "openDiff",
      arguments = {
        old_file_path = path,
        new_file_path = path,
        new_file_contents = "alpha accepted\n",
        tab_name = tab_name_of(file),
      },
    })
    assert.is_true(call._deferred, vim.inspect(call.error))
    _G.claude_deferred_responses[tostring(call.coroutine)] = function() end
    return diff._get_active_diffs()[tab_name_of(file)]
  end

  local function close_tab(file)
    tools.handle_invoke(
      { id = "float_spec_close_" .. file },
      { name = "close_tab", arguments = { tab_name = tab_name_of(file) } }
    )
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    for _, name in ipairs({ "proposed.txt", "second.txt" }) do
      vim.fn.writefile({ "alpha" }, dir .. "/" .. name)
    end
    tools.register_all()
    _G.claude_deferred_responses = {}
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/proposed.txt"))
    float = install_float_terminal()
  end)

  after_each(function()
    diff._cleanup_all_active_diffs("test cleanup")
    vim.cmd("silent! stopinsert")
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    package.loaded["claudecode.terminal"] = nil
    vim.fn.delete(dir, "rf")
    _G.claude_deferred_responses = nil
  end)

  for _, layout in ipairs({ "vertical", "unified" }) do
    it("hides the float while a " .. layout .. " diff is open and shows it again on close_tab", function()
      setup_diff({ layout = layout })
      assert.equal(1, #visible_floats(), "the float starts visible")

      local diff_data = open_diff("proposed.txt")

      assert.equal(0, #visible_floats(), "no float covers the diff")
      assert.equal(1, float.hide_calls)
      assert.equal(diff_data.new_window, vim.api.nvim_get_current_win(), "focus is in the diff")

      close_tab("proposed.txt")

      assert.equal(1, #visible_floats(), "the float is back after the diff closes")
      assert.equal(1, float.show_calls)
      assert.is_not.equal(
        float.win,
        vim.api.nvim_get_current_win(),
        "the float does not take focus from the editor window"
      )
    end)
  end

  local it_parks_floats = vim.fn.has("nvim-0.10") == 1 and it
    or function(name)
      pending(name .. " (needs Neovim 0.10)")
    end

  for _, layout in ipairs({ "vertical", "unified" }) do
    it_parks_floats(
      "returns the cursor to the float when the user was typing in it as a " .. layout .. " diff opened",
      function()
        setup_diff({ layout = layout })
        vim.api.nvim_set_current_win(float.win)

        open_diff("proposed.txt")
        assert.is_not.equal(float.win, vim.api.nvim_get_current_win(), "the diff has focus while it is open")
        close_tab("proposed.txt")

        assert.equal(1, #visible_floats())
        assert.equal(float.win, vim.api.nvim_get_current_win(), "the cursor is back where the user left it")
      end
    )
  end

  it("leaves the float and its focus alone when keep_terminal_focus is set", function()
    setup_diff({ layout = "vertical", keep_terminal_focus = true })

    open_diff("proposed.txt")
    vim.wait(200, function()
      return vim.api.nvim_get_current_win() == float.win
    end)

    assert.equal(0, float.hide_calls)
    assert.equal(1, #visible_floats())
    assert.equal(float.win, vim.api.nvim_get_current_win(), "focus returns to the float")

    close_tab("proposed.txt")
    assert.equal(0, float.show_calls)
    assert.equal(1, #visible_floats())
  end)

  it("leaves the float in the original tab when the diff opens in a new tab", function()
    setup_diff({ layout = "vertical", open_in_new_tab = true })
    local original_tab = vim.api.nvim_get_current_tabpage()

    local diff_data = open_diff("proposed.txt")

    assert.is_true(diff_data.created_new_tab)
    assert.equal(0, float.hide_calls)
    assert.equal(1, #visible_floats(original_tab), "the float stays in the tab the user left")

    close_tab("proposed.txt")
    assert.equal(0, float.hide_calls)
    assert.equal(1, #visible_floats(original_tab))
  end)

  it("leaves the float in the original tab when the new tab shows no terminal", function()
    setup_diff({ layout = "vertical", open_in_new_tab = true, hide_terminal_in_new_tab = true })
    local original_tab = vim.api.nvim_get_current_tabpage()

    local diff_data = open_diff("proposed.txt")

    assert.is_true(diff_data.created_new_tab)
    assert.equal(0, float.hide_calls)
    assert.equal(1, #visible_floats(original_tab))
  end)

  it("leaves the float alone when the terminal provider cannot hide one", function()
    float = install_float_terminal({ without_hide_float = true })
    setup_diff({ layout = "vertical" })

    open_diff("proposed.txt")
    assert.equal(1, #visible_floats())
    vim.api.nvim_win_close(float.win, true)
    float.win = nil
    close_tab("proposed.txt")

    assert.equal(0, float.show_calls, "a float that no diff hid stays as the user left it")
  end)

  it("keeps the float hidden until the last of two unified diffs closes", function()
    setup_diff({ layout = "unified" })

    open_diff("proposed.txt")
    open_diff("second.txt")
    assert.equal(0, #visible_floats())
    assert.equal(1, float.hide_calls)

    close_tab("proposed.txt")
    assert.equal(0, #visible_floats(), "the second diff is still open")

    close_tab("second.txt")
    assert.equal(1, #visible_floats())
    assert.equal(1, float.show_calls)
  end)

  it("keeps the float hidden when a second diff opens in a new tab and closes first", function()
    setup_diff({ layout = "vertical" })
    local first_tab = vim.api.nvim_get_current_tabpage()

    open_diff("proposed.txt")
    local second = open_diff("second.txt")
    assert.is_true(second.created_new_tab, "a tab that already has a diff gets the second one in a new tab")

    close_tab("second.txt")

    assert.equal(first_tab, vim.api.nvim_get_current_tabpage())
    assert.equal(0, #visible_floats(), "the first diff is still open")
    assert.equal(0, float.show_calls)

    close_tab("proposed.txt")
    assert.equal(1, #visible_floats())
  end)

  it("does not show a float the user hid before the diff opened", function()
    setup_diff({ layout = "vertical" })
    float.user_hide()

    open_diff("proposed.txt")
    close_tab("proposed.txt")

    assert.equal(0, float.hide_calls)
    assert.equal(0, float.show_calls)
    assert.equal(0, #visible_floats())
  end)

  it_parks_floats("keeps focus in the diff when keep_terminal_focus is set and the user hid the float", function()
    setup_diff({ layout = "vertical", keep_terminal_focus = true })
    float.user_hide()

    local diff_data = open_diff("proposed.txt")
    vim.wait(100, function()
      return vim.api.nvim_get_current_win() ~= diff_data.new_window
    end)

    assert.equal(diff_data.new_window, vim.api.nvim_get_current_win(), "focus does not go into a hidden window")
  end)

  it_parks_floats("keeps a float the user hid hidden when the diff opens in its own tab", function()
    setup_diff({ layout = "vertical", open_in_new_tab = true })
    local original_tab = vim.api.nvim_get_current_tabpage()
    float.user_hide()

    open_diff("proposed.txt")
    close_tab("proposed.txt")

    assert.equal(0, float.ensure_calls, "a hidden float is not a terminal in the original tab")
    assert.equal(0, #visible_floats(original_tab))
  end)

  it("hides the float again when the user brought it back and a second diff opens in the tab", function()
    setup_diff({ layout = "unified" })

    open_diff("proposed.txt")
    float.user_show()
    assert.equal(1, #visible_floats())

    open_diff("second.txt")
    assert.equal(0, #visible_floats(), "the float does not cover the second diff")

    close_tab("proposed.txt")
    assert.equal(0, #visible_floats(), "the second diff is still open")
    close_tab("second.txt")
    assert.equal(1, #visible_floats())
  end)

  it_parks_floats("does not put the cursor in a float the user hid during the diff", function()
    setup_diff({ layout = "vertical" })
    vim.api.nvim_set_current_win(float.win)

    open_diff("proposed.txt")
    float.user_show()
    float.user_hide()
    close_tab("proposed.txt")

    local current = vim.api.nvim_get_current_win()
    assert.is_not.equal(float.win, current, "the cursor is not in the hidden float")
    assert.is_not.equal(true, vim.api.nvim_win_get_config(current).hide)
    assert.equal(0, #visible_floats(), "the float stays hidden")
  end)

  it("keeps the float hidden after the user rejects with :q, until close_tab", function()
    setup_diff({ layout = "vertical" })

    local diff_data = open_diff("proposed.txt")
    vim.api.nvim_set_current_win(diff_data.new_window)
    vim.cmd("quit")
    assert.equal("rejected", diff._get_active_diffs()[tab_name_of("proposed.txt")].status)
    assert.equal(0, #visible_floats(), "the diff is still open until close_tab")

    close_tab("proposed.txt")
    assert.equal(1, #visible_floats())
  end)

  it_parks_floats("does not wait for a diff in another tab before it shows the float", function()
    setup_diff({ layout = "vertical" })
    local first_tab = vim.api.nvim_get_current_tabpage()

    open_diff("proposed.txt")
    vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/second.txt"))
    local second = open_diff("second.txt")
    assert.is_false(second.created_new_tab)
    vim.api.nvim_set_current_tabpage(first_tab)

    close_tab("proposed.txt")

    assert.equal(1, #visible_floats(first_tab), "the first tab's diff is done, so its float is back")
  end)

  it_parks_floats("leaves the float hidden when the diff closes while the user is in another tab", function()
    setup_diff({ layout = "vertical" })
    local first_tab = vim.api.nvim_get_current_tabpage()

    open_diff("proposed.txt")
    vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/second.txt"))
    close_tab("proposed.txt")

    assert.equal(0, #visible_floats(first_tab), "the float stays hidden: Snacks would re-create it in this tab")
    assert.equal(0, float.show_calls)
  end)

  it("leaves the terminal alone when another window shows it as the diff closes", function()
    setup_diff({ layout = "vertical" })

    open_diff("proposed.txt")
    vim.cmd("botright vsplit")
    vim.api.nvim_win_set_buf(0, float.buf)
    close_tab("proposed.txt")

    assert.equal(0, float.show_calls, "the user already has the terminal in a split")
    assert.equal(0, #visible_floats())
  end)

  it("leaves a float the user moved to another tab visible when a diff opens in this tab", function()
    setup_diff({ layout = "unified" })
    local first_tab = vim.api.nvim_get_current_tabpage()

    open_diff("proposed.txt")
    float.user_show()
    vim.api.nvim_win_close(float.win, true)
    float.win = nil
    vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/second.txt"))
    local float_tab = vim.api.nvim_get_current_tabpage()
    float.user_show()
    assert.equal(1, #visible_floats(float_tab), "the user moved the float into the second tab")
    vim.api.nvim_set_current_tabpage(first_tab)

    local second = open_diff("second.txt")

    assert.equal(first_tab, vim.api.nvim_win_get_tabpage(second.new_window), "the second diff is in the first tab")
    assert.equal(1, #visible_floats(float_tab), "a diff in the first tab must not hide the second tab's float")
    assert.equal(1, float.hide_calls, "only the first diff hid the float")
  end)

  it("hides a float the user re-created in another tab while an earlier diff is still open", function()
    setup_diff({ layout = "vertical" })

    open_diff("proposed.txt")
    vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/second.txt"))
    if float.win and vim.api.nvim_win_is_valid(float.win) then
      vim.api.nvim_win_close(float.win, true)
      float.win = nil
    end
    float.user_show()
    assert.equal(1, #visible_floats(), "the user has the float in the second tab")

    local second = open_diff("second.txt")

    assert.is_false(second.created_new_tab)
    assert.equal(0, #visible_floats(), "the float does not cover the diff in the second tab")
  end)

  for _, kind in ipairs({
    { name = "a provider that checks the token", own_mark = false },
    { name = "a provider that keeps its own mark", own_mark = true },
  }) do
    it(
      "keeps the float hidden over a later diff when the earlier diff closes in another tab, with " .. kind.name,
      function()
        float = install_float_terminal({ own_mark = kind.own_mark })
        setup_diff({ layout = "vertical" })
        local first_tab = vim.api.nvim_get_current_tabpage()

        -- The first diff hides the float. The user shows it again and closes it with :close.
        open_diff("proposed.txt")
        float.user_show()
        vim.api.nvim_win_close(float.win, true)
        float.win = nil

        -- The user opens a second tab and runs :ClaudeCodeFocus, which re-creates the float there. A second diff hides it.
        vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/second.txt"))
        local second_tab = vim.api.nvim_get_current_tabpage()
        float.user_show()
        local second = open_diff("second.txt")
        assert.is_false(second.created_new_tab)
        assert.equal(0, #visible_floats(second_tab), "the second diff hid the float")

        vim.api.nvim_set_current_tabpage(first_tab)
        close_tab("proposed.txt")

        assert.equal(0, #visible_floats(second_tab), "the first diff does not put the float over the second diff")
        assert.equal(0, #visible_floats(first_tab))
        assert.equal(0, float.show_calls)

        vim.api.nvim_set_current_tabpage(second_tab)
        close_tab("second.txt")
        assert.equal(1, #visible_floats(second_tab), "the float comes back when the diff that hid it closes")
      end
    )
  end

  it("keeps a float hidden that the user hid again when a second diff opens in the tab", function()
    setup_diff({ layout = "unified" })

    open_diff("proposed.txt")
    float.user_show()
    float.user_hide()
    open_diff("second.txt")
    assert.equal(1, float.hide_calls, "the second diff found the float hidden and hid nothing")

    close_tab("proposed.txt")
    close_tab("second.txt")

    assert.equal(0, #visible_floats(), "the user hid the float after the first diff did")
    assert.equal(0, float.show_calls)
  end)

  it("shows the float when the last diff closes, if that diff shared the newest hide", function()
    setup_diff({ layout = "unified" })

    open_diff("proposed.txt")
    float.user_show()
    open_diff("second.txt")
    assert.equal(2, float.hide_calls, "the second diff hid the float again")

    vim.fn.writefile({ "alpha" }, dir .. "/third.txt")
    open_diff("third.txt")
    assert.equal(2, float.hide_calls, "the third diff found the float hidden")

    close_tab("proposed.txt")
    close_tab("second.txt")
    assert.equal(0, #visible_floats(), "the third diff is still open")
    close_tab("third.txt")

    assert.equal(1, #visible_floats(), "the float comes back, as the third diff shares the second diff's hide")
  end)

  it_parks_floats("puts the cursor in the editor window when the window it was in is a hidden float", function()
    setup_diff({ layout = "unified" })
    local editor_win = vim.api.nvim_get_current_win()

    open_diff("proposed.txt")
    float.user_show()
    vim.api.nvim_set_current_win(float.win)
    open_diff("second.txt")
    assert.equal(0, #visible_floats(), "the second diff hides the float again")
    close_tab("second.txt")

    assert.equal(editor_win, vim.api.nvim_get_current_win(), "not the hidden float, and not the first diff's window")
  end)

  for _, layout in ipairs({ "vertical", "unified" }) do
    it("hides a float the user opened in another tab after an earlier " .. layout .. " diff closed", function()
      setup_diff({ layout = layout })
      open_diff("proposed.txt")
      close_tab("proposed.txt")
      assert.equal(1, #visible_floats(), "the float is back in the first tab")

      vim.api.nvim_win_close(float.win, true)
      float.win = nil
      vim.cmd("tabnew " .. vim.fn.fnameescape(dir .. "/second.txt"))
      float.user_show()
      assert.equal(1, #visible_floats(), "the user has the float in the second tab")

      local second = open_diff("second.txt")

      assert.is_false(second.created_new_tab)
      assert.equal(0, #visible_floats(), "the float does not cover the diff in the second tab")
    end)
  end
end)
