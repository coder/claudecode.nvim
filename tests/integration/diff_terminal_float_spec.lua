-- Real-Neovim checks of openDiff while the Claude terminal is a floating window (issue #180). A float is not a
-- tiled window, so the diff cannot make room for it the way it does for a split: the diff hides the float and
-- shows it again when the diff closes. Window geometry needs a real Neovim, so under busted's mock vim this is
-- pending; scripts/run_integration_tests_individually.sh runs it in Neovim.
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
  local float -- the fake terminal: { buf, win, hide_calls, show_calls }

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

  -- A terminal provider whose terminal lives in a real floating window, with the hooks a float needs.
  local function install_float_terminal(opts)
    local fake = { hide_calls = 0, show_calls = 0 }
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
    local function show_window()
      if fake.win and vim.api.nvim_win_is_valid(fake.win) then
        vim.api.nvim_win_set_config(fake.win, { hide = false })
      else
        open_window()
      end
    end

    -- Hides the window the way a user's own hide key does, without a diff being involved.
    function fake.user_hide()
      hide_window()
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
        fake.hide_calls = fake.hide_calls + 1
        return true
      end,
      ensure_visible = function()
        if not window_is_open() then
          fake.show_calls = fake.show_calls + 1
          show_window()
        end
      end,
    }
    if opts and opts.without_hide_float then
      provider.hide_float = nil
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

  -- Before Neovim 0.10 a float is closed, not parked, so its window is a new one when it comes back.
  local it_parks_floats = vim.fn.has("nvim-0.10") == 1 and it
    or function(name)
      pending(name .. " (needs Neovim 0.10)")
    end

  it_parks_floats("returns the cursor to the float when the user was typing in it as the diff opened", function()
    setup_diff({ layout = "vertical" })
    vim.api.nvim_set_current_win(float.win)

    open_diff("proposed.txt")
    assert.is_not.equal(float.win, vim.api.nvim_get_current_win(), "the diff has focus while it is open")
    close_tab("proposed.txt")

    assert.equal(1, #visible_floats())
    assert.equal(float.win, vim.api.nvim_get_current_win(), "the cursor is back where the user left it")
  end)

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

  it("does not start a new terminal when Claude's terminal is gone by the time the diff closes", function()
    setup_diff({ layout = "vertical" })

    open_diff("proposed.txt")
    vim.api.nvim_buf_delete(float.buf, { force = true })
    close_tab("proposed.txt")

    assert.equal(0, float.show_calls)
  end)
end)
