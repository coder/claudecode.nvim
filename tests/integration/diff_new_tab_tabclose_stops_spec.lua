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

  -- The user's modified b.txt window, opened in the diff tab with 'nohidden', stops :tabclose with E37.
  local function open_diff_with_modified_user_buffer(first_tab_after)
    child.call([[vim.o.hidden = false]])
    child.open_diff("a.txt", "first diff")
    child.call([[
      vim.cmd("split " .. _G.dir .. "/b.txt")
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "one!" })
    ]])
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
end)
