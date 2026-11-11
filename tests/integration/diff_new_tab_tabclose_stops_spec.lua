if vim == nil or vim.fn.has("nvim") ~= 1 then
  describe("a diff tab that :tabclose cannot close because of a modified buffer of the user's", function()
    pending("needs a real Neovim")
  end)
  return
end

local helper = require("tests.helpers.new_tab_diff_child")

describe("a diff tab that :tabclose cannot close because of a modified buffer of the user's", function()
  local child = helper.new()

  after_each(child.stop)

  -- The user's modified b.txt window, opened in the diff tab with 'nohidden', stops :tabclose with E37. `:tabclose` closes
  -- the windows of the tab from the last one back and stops at the first it cannot close: a modified window at the
  -- right leaves every window of the diff open, one above leaves none of those that follow it.
  local function open_diff_with_modified_user_buffer(first_tab_after, modified_window_at_right)
    child.call([[vim.o.hidden = false]])
    child.open_diff("a.txt", "first diff")
    child.call(
      [[
      local at_right = ...
      vim.cmd((at_right and "botright vsplit " or "split ") .. _G.dir .. "/b.txt")
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "one!" })
    ]],
      modified_window_at_right or false
    )
    if first_tab_after then
      child.go_to_first_tab()
    end
  end

  local function tab_leftovers(n)
    return child.call(
      [[
      local tab = vim.api.nvim_list_tabpages()[...]
      local diff, term = 0, 0
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.wo[win].diff or vim.wo[win].scrollbind or vim.wo[win].foldmethod == "diff" then
          diff = diff + 1
        end
        if vim.api.nvim_win_get_buf(win) == _G.terminal_buf then
          term = term + 1
        end
      end
      return { diff = diff, term = term }
    ]],
      n
    )
  end

  it("closes the diff's windows, keeps the user's, and leaves the user in their tab in Normal mode", function()
    child.start({ layout = "vertical", show_terminal_again = true })
    open_diff_with_modified_user_buffer(true)

    child.close_diff("first diff")
    local state = child.state()

    assert.equal(2, state.tabs)
    assert.equal("n", state.mode)
    assert.is_true(state.name:find("a.txt", 1, true) ~= nil, state.name)
    assert.equal(0, child.leftovers().handlers)
    local diff_tab = child.call([[
      local names = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_list_tabpages()[2])) do
        local buf = vim.api.nvim_win_get_buf(win)
        local name = vim.bo[buf].buftype == "terminal" and "TERMINAL" or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
        table.insert(names, name .. (vim.bo[buf].modified and "+" or ""))
      end
      table.sort(names)
      return names
    ]])
    assert.same({ "a.txt", "b.txt+" }, diff_tab)
  end)

  it("turns diff mode off in the diff tab's windows", function()
    child.start({ layout = "vertical", show_terminal_again = true })
    open_diff_with_modified_user_buffer(true)

    child.close_diff("first diff")
    child.state()

    assert.equal(0, tab_leftovers(2).diff)
  end)

  it("closes the diff's terminal window and its handler when the terminal is on the left", function()
    child.start({ layout = "vertical", show_terminal_again = true })
    child.call([[
      local config = vim.deepcopy(require("claudecode.config").defaults)
      config.diff_opts.open_in_new_tab = true
      config.terminal = config.terminal or {}
      config.terminal.split_side = "left"
      require("claudecode.diff").setup(config)
    ]])
    open_diff_with_modified_user_buffer(true)

    child.close_diff("first diff")
    child.state()

    assert.equal(0, tab_leftovers(2).term)
    assert.equal(0, child.leftovers().handlers)
  end)

  local function expect_closed_without_error_or_leftovers()
    local leftovers = child.call([[
      return {
        records = vim.tbl_count(require("claudecode.diff")._get_active_diffs()),
        proposal_loaded = vim.api.nvim_buf_is_valid(_G.proposal_buf) and vim.api.nvim_buf_is_loaded(_G.proposal_buf),
      }
    ]])

    assert.equal(0, leftovers.records, "the diff must leave no record")
    assert.is_false(leftovers.proposal_loaded, "the proposal buffer must be gone")
  end

  for _, case in ipairs({
    {
      layout = "unified",
      current = "proposal",
      event = "BufNew",
      step = "creating the buffer for the proposal window",
    },
    { layout = "vertical", current = "terminal", event = "WinClosed", step = "closing the terminal window" },
  }) do
    it(
      "runs no "
        .. case.event
        .. " autocmd of the user's, which could close the tab, while "
        .. case.step
        .. ", with layout = "
        .. case.layout,
      function()
        child.start({ layout = case.layout, show_terminal_again = true })
        open_diff_with_modified_user_buffer(true, true)
        child.call(
          [[
          local event = ...
          local diff_data = require("claudecode.diff")._get_active_diffs()["first diff"]
          _G.proposal_buf = diff_data.new_buffer
          _G.ran = false
          vim.api.nvim_create_autocmd(event, {
            pattern = event == "WinClosed" and tostring(diff_data.terminal_win_in_new_tab) or nil,
            callback = function()
              if not _G.ran then
                _G.ran = true
                vim.cmd("tabclose! 2")
              end
            end,
          })
        ]],
          case.event
        )

        child.close_diff("first diff")
        local state = child.state()

        assert.is_false(child.call([[return _G.ran]]), "no autocmd may run while the release changes a window")
        assert.equal(2, state.tabs)
        expect_closed_without_error_or_leftovers()
      end
    )
  end

  it("survives an autocmd of the user's that closes the tab while the cursor leaves the proposal window", function()
    child.start({ layout = "vertical", show_terminal_again = true })
    open_diff_with_modified_user_buffer(false)
    child.call([[
      _G.proposal_buf = require("claudecode.diff")._get_active_diffs()["first diff"].new_buffer
      _G.diff_tab = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
      vim.cmd("tabclose")
      vim.api.nvim_set_current_tabpage(_G.diff_tab)
    ]])
    child.call(
      [[vim.api.nvim_set_current_win(require("claudecode.diff")._get_active_diffs()["first diff"].new_window)]]
    )
    child.call([[
      _G.ran = false
      vim.api.nvim_create_autocmd("BufEnter", {
        callback = function()
          if not _G.ran then
            _G.ran = true
            vim.cmd("tabclose! " .. vim.api.nvim_tabpage_get_number(_G.diff_tab))
          end
        end,
      })
    ]])

    child.close_diff("first diff")
    child.state()

    assert.is_true(child.call([[return _G.ran]]), "the BufEnter autocmd must run while the cursor moves")
    assert.is_false(child.call([[return vim.api.nvim_tabpage_is_valid(_G.diff_tab)]]))
    expect_closed_without_error_or_leftovers()
  end)

  it("does nothing when the tab page is already gone", function()
    child.start({ layout = "vertical", show_terminal_again = true })
    child.open_diff("a.txt", "first diff")

    local result = child.call([[
      local diff_data = vim.deepcopy(require("claudecode.diff")._get_active_diffs()["first diff"])
      vim.cmd("tabnew")
      diff_data.new_tab_number = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabclose")
      return { pcall(require("claudecode.diff")._release_surviving_diff_tab, diff_data) }
    ]])

    assert.is_true(result[1], tostring(result[2]))
  end)
end)
