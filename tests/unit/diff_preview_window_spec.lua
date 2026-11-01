-- Issue #385: with only the preview window and the Claude terminal in the tab, and the cursor in the
-- preview window, a side-by-side diff must not go into the preview window or into a split of it. The
-- preview window has 'winfixheight' and 'previewheight' lines, so a vertical split of it is that short too.
require("tests.busted_setup")
local temp_dir = require("tests.helpers.temp_dir")

describe("Diff with the preview window as the only editor window (issue #385)", function()
  local diff
  local preview_win, terminal_win = 1000, 1001
  local preview_height, terminal_height = 12, 25
  local preview_buf, terminal_buf
  local dir, old_file
  setup(function()
    dir = temp_dir.new()
    old_file = dir .. "/claudecode_preview_window_old.txt"
  end)
  teardown(function()
    temp_dir.remove(dir)
  end)

  local function setup_diff()
    package.loaded["claudecode.diff"] = nil
    diff = require("claudecode.diff")
    diff.setup({
      diff_opts = { layout = "vertical", open_in_new_tab = false, keep_terminal_focus = false },
      terminal = {},
    })
  end

  before_each(function()
    vim._mock.reset()
    vim._tabs = { [1] = true }
    vim._current_tabpage = 1
    vim._next_winid = 1002

    preview_buf = vim.api.nvim_create_buf(true, false)
    vim._buffers[preview_buf].name = "/tmp/other.txt"
    terminal_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(terminal_buf, "buftype", "terminal")
    vim._windows[preview_win] = { buf = preview_buf, width = 160, height = preview_height }
    vim.api.nvim_win_set_option(preview_win, "previewwindow", true)
    vim._windows[terminal_win] = { buf = terminal_buf, width = 160, height = terminal_height }
    vim._win_tab[preview_win] = 1
    vim._win_tab[terminal_win] = 1
    vim._tab_windows[1] = { preview_win, terminal_win }
    vim._current_window = preview_win

    package.loaded["claudecode.logger"] =
      { debug = function() end, error = function() end, info = function() end, warn = function() end }
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function()
        return terminal_buf
      end,
      ensure_visible = function() end,
    }

    local f = assert(io.open(old_file, "w"))
    f:write("alpha\nbeta\ngamma\n")
    f:close()
  end)

  after_each(function()
    if diff then
      diff._cleanup_all_active_diffs("test teardown")
    end
    os.remove(old_file)
    package.loaded["claudecode.diff"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.logger"] = nil
  end)

  local function open_blocking_diff(tab_name)
    diff._setup_blocking_diff({
      old_file_path = old_file,
      new_file_path = old_file,
      new_file_contents = "alpha\nBETA\ngamma\n",
      tab_name = tab_name,
    }, function() end)
    return diff._get_active_diffs()[tab_name]
  end

  it("openDiff gives both panes the terminal's height and closes its fallback window on cleanup", function()
    setup_diff()
    local state = open_blocking_diff("side-by-side")

    assert.equals(terminal_height, vim.api.nvim_win_get_height(state.target_window))
    assert.equals(terminal_height, vim.api.nvim_win_get_height(state.new_window))
    assert.equals(preview_buf, vim.api.nvim_win_get_buf(preview_win))

    diff._cleanup_diff_state("side-by-side", "test cleanup")
    assert.is_false(vim.api.nvim_win_is_valid(state.fallback_window))
    assert.same({ preview_win, terminal_win }, vim.api.nvim_tabpage_list_wins(1))
  end)

  -- The mock does not move the cursor for `wincmd t` and `wincmd l`. In this layout Neovim lands on the
  -- preview window too: it is the top-left window and has no window to its right.
  it("the legacy diff.open_diff keeps the preview window's file and gives the diff the terminal's height", function()
    setup_diff()
    -- The mock's mkdir creates no directory, so the proposed text's temp file cannot be written for real.
    local real_open = io.open
    rawset(io, "open", function(path, mode)
      if mode == "w" and path:find("/claudecode_diffs/", 1, true) then
        return { write = function() end, close = function() end }
      end
      return real_open(path, mode)
    end)
    finally(function()
      rawset(io, "open", real_open)
    end)
    local result = diff.open_diff(old_file, old_file, "alpha\nBETA\ngamma\n", "legacy")

    assert.is_true(result.success)
    assert.equals(preview_buf, vim.api.nvim_win_get_buf(preview_win))
    assert.equals(terminal_height, vim.api.nvim_win_get_height(vim.api.nvim_get_current_win()))
  end)
end)
