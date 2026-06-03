-- Regression coverage for find_main_editor_window's sidebar/explorer exclusion.
--
-- Issue #236: the Snacks Explorer (LazyVim default) renders its sidebar as a
-- NON-floating split window with filetype "snacks_layout_box" (buftype
-- "nofile"); its picker list/input float on top. find_main_editor_window must
-- skip the layout box so Claude's diffs open in the real editor window instead
-- of corrupting the explorer sidebar.
require("tests.busted_setup")

describe("diff.find_main_editor_window sidebar exclusion", function()
  local diff
  local saved

  -- Build a fake window layout and stub the four vim.api calls the function uses.
  -- `wins` is an ordered list of { ft=, bt=, floating= } describing each window.
  local function with_layout(wins)
    local win_ids, buf_of, opt_of, cfg_of = {}, {}, {}, {}
    for i, w in ipairs(wins) do
      local win_id = 1000 + i
      local buf_id = 2000 + i
      win_ids[i] = win_id
      buf_of[win_id] = buf_id
      opt_of[buf_id] = { buftype = w.bt or "", filetype = w.ft or "" }
      cfg_of[win_id] = { relative = w.floating and "editor" or "" }
    end

    _G.vim.api.nvim_list_wins = function()
      return win_ids
    end
    _G.vim.api.nvim_win_get_buf = function(win)
      return buf_of[win]
    end
    _G.vim.api.nvim_buf_get_option = function(buf, name)
      return opt_of[buf][name]
    end
    _G.vim.api.nvim_win_get_config = function(win)
      return cfg_of[win]
    end

    return win_ids
  end

  before_each(function()
    saved = {
      nvim_list_wins = _G.vim.api.nvim_list_wins,
      nvim_win_get_buf = _G.vim.api.nvim_win_get_buf,
      nvim_buf_get_option = _G.vim.api.nvim_buf_get_option,
      nvim_win_get_config = _G.vim.api.nvim_win_get_config,
    }
    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")
  end)

  after_each(function()
    for name, fn in pairs(saved) do
      _G.vim.api[name] = fn
    end
    package.loaded["claudecode.diff"] = nil
  end)

  it("skips the Snacks Explorer layout box and returns the real editor (issue #236)", function()
    -- Snacks Explorer sidebar is window 1, the real editor is window 2.
    local wins = with_layout({
      { ft = "snacks_layout_box", bt = "nofile" }, -- explorer container (non-floating split)
      { ft = "lua", bt = "" }, -- the actual editor
    })

    expect(diff._find_main_editor_window()).to_be(wins[2])
  end)

  it("skips snacks_picker_list sidebars (regression for #165)", function()
    local wins = with_layout({
      { ft = "snacks_picker_list", bt = "nofile" },
      { ft = "lua", bt = "" },
    })

    expect(diff._find_main_editor_window()).to_be(wins[2])
  end)

  it("skips common file-explorer and outline sidebars", function()
    for _, ft in ipairs({ "neo-tree", "NvimTree", "oil", "minifiles", "netrw", "aerial", "tagbar" }) do
      local wins = with_layout({
        { ft = ft, bt = "" },
        { ft = "text", bt = "" },
      })
      expect(diff._find_main_editor_window()).to_be(wins[2])
    end
  end)

  it("skips terminal, prompt, and floating windows", function()
    local wins = with_layout({
      { ft = "", bt = "terminal" }, -- Claude terminal
      { ft = "", bt = "prompt" }, -- picker input
      { ft = "lua", bt = "", floating = true }, -- floating window
      { ft = "go", bt = "" }, -- the actual editor
    })

    expect(diff._find_main_editor_window()).to_be(wins[4])
  end)

  it("returns nil when only excluded windows exist", function()
    with_layout({
      { ft = "snacks_layout_box", bt = "nofile" },
      { ft = "", bt = "terminal" },
    })

    expect(diff._find_main_editor_window()).to_be(nil)
  end)
end)
